-- subshell -- a real shell port for one host that decided to have one (docs/spec/subshell.md).
--
--     local sh = require("subshell").port(root, { env = { PATH = "...", HOME = root }, log = fn })
--     sh.run({ "sh", "-c", "npm test" }, { cwd = "pkg", timeout = 600 })
--
-- The child runs under `root` with `env -i` and only `cfg.env`, so no key of this process
-- reaches it; `perl -e alarm` is the deadline, because macOS has no `timeout`.

local port = require "port"

local subshell = {}

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local t = f:read("*a"); f:close(); return t
end

local function exists_dir(path)
  local f = io.open(path .. "/.", "r")
  if f then f:close(); return true end
  return false
end

--- The port. `root` is an absolute directory; `cfg.env` the whole of the child's
--- environment (PATH at least, or nothing runs); `cfg.log(line)` sees one line a command.
function subshell.port(root, cfg)
  if type(root) ~= "string" or root == "" then error("subshell.port: root is an absolute directory", 2) end
  cfg = cfg or {}
  local env = cfg.env or { PATH = "/usr/bin:/bin" }
  local log = type(cfg.log) == "function" and cfg.log or function () end
  local p = {}

  function p.run(argv, opts)
    port.shape.argv("sh.run", argv)
    opts = opts or {}
    port.shape.opts("sh.run", opts)
    local dir = root
    if opts.cwd ~= nil and opts.cwd ~= "" and opts.cwd ~= "." then
      if not port.path_ok(opts.cwd) then
        return nil, port.error("sh", "run", "denied", "cwd leaves the workspace: " .. tostring(opts.cwd))
      end
      dir = root .. "/" .. opts.cwd
      if not exists_dir(dir) then
        return nil, port.error("sh", "run", "denied", "no such directory under the workspace: " .. tostring(opts.cwd))
      end
    end
    local timeout = tonumber(opts.timeout) or 30

    local out_f, err_f, code_f = os.tmpname(), os.tmpname(), os.tmpname()
    local in_f
    if opts.stdin ~= nil then
      in_f = os.tmpname()
      local f = assert(io.open(in_f, "wb")); f:write(opts.stdin); f:close()
    end

    local parts = { "cd", sh_quote(dir), "&&", "env", "-i" }
    for k, v in pairs(env) do parts[#parts + 1] = sh_quote(k .. "=" .. v) end
    parts[#parts + 1] = "perl -e 'alarm shift @ARGV; exec @ARGV or exit 127'"
    parts[#parts + 1] = tostring(math.max(1, math.floor(timeout)))
    for i = 1, #argv do parts[#parts + 1] = sh_quote(argv[i]) end
    local line = table.concat(parts, " ")
      .. " <" .. sh_quote(in_f or "/dev/null") .. " >" .. sh_quote(out_f) .. " 2>" .. sh_quote(err_f)
      .. "; echo $? >" .. sh_quote(code_f)

    local t0 = os.time()
    -- the outer shell's own stderr is dropped: it announces a killed child ("Alarm clock")
    os.execute("sh -c " .. sh_quote(line) .. " 2>/dev/null")
    local took = os.time() - t0
    local code = tonumber((read_all(code_f):match("%d+"))) or 1
    local out, err = read_all(out_f), read_all(err_f)
    os.remove(out_f); os.remove(err_f); os.remove(code_f)
    if in_f then os.remove(in_f) end

    local said = table.concat(argv, " ")
    if code == 142 then                      -- 128 + SIGALRM: the deadline
      log(string.format("timeout after %ds: %s", timeout, said))
      return nil, port.error("sh", "run", "timeout", "killed after " .. timeout .. " seconds")
    end
    log(string.format("exit %d in %ds: %s", code, took, said))
    if code == 127 and out == "" then
      return nil, port.error("sh", "run", "not_found", "no such program: " .. tostring(argv[1]))
    end
    return { code = code, out = out, err = err, timed_out = false }
  end

  return p
end

return subshell
