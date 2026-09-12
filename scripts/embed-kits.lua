-- Rewrites every embedded copy of a library kit in evals/*.feature from the library file.
-- A feature that runs an author against a notebook file carries the kit as a doc string
-- under `And the file "agents/<kit>.lua" contains:`, because the notebook is read through
-- the doubles' filesystem; the registry refuses a kit whose text differs from the one
-- already loaded by name (docs/spec/kit.md), so a stale copy fails every nested verify.
--
--     lua scripts/embed-kits.lua            -- rewrite, and say which files changed
--     lua scripts/embed-kits.lua --check    -- exit 1 naming a stale copy, writing nothing
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = here .. "/.."
local check = arg[1] == "--check"

local function read(p) local f = io.open(p, "rb"); if not f then return nil end local t = f:read("a"); f:close(); return t end
local function write(p, t) local f = assert(io.open(p, "wb")); f:write(t); f:close() end
local function list(dir)
  local out, p = {}, io.popen('ls "' .. dir .. '"')
  for name in p:lines() do if name:match("%.feature$") then out[#out + 1] = name end end
  p:close(); return out
end

local stale = 0
for _, name in ipairs(list(root .. "/evals")) do
  local path = root .. "/evals/" .. name
  local text = read(path)
  local out, changed, pos = {}, false, 1
  while true do
    local s, e, kit = text:find('    And the file "agents/([%w_%-]+%.lua)" contains:\n      """\n', pos)
    if not s then break end
    local lib = read(root .. "/library/" .. kit)
    if not lib then break end
    local close_s, close_e = text:find('\n      """\n', e + 1, true)
    if not close_s then break end
    local body = {}
    for line in (lib:gsub("\n$", "") .. "\n"):gmatch("(.-)\n") do
      body[#body + 1] = line == "" and "" or ("      " .. line)
    end
    local fresh = table.concat(body, "\n")
    if text:sub(e + 1, close_s - 1) ~= fresh then changed = true end
    out[#out + 1] = text:sub(pos, e) .. fresh
    pos = close_s
  end
  out[#out + 1] = text:sub(pos)
  if changed then
    stale = stale + 1
    if check then io.stderr:write("stale embedded kit in evals/" .. name .. "\n")
    else write(path, table.concat(out)); io.write("evals/" .. name .. " rewritten\n") end
  end
end
if check and stale > 0 then os.exit(1) end
io.write(stale == 0 and "every embedded kit matches its library file\n" or "")
