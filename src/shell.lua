-- shell -- a shell, in Lua, over a filesystem in Lua. No host, no subprocess, no clock.
--
-- `src/tools_shell.lua` is the TOOL: what a model calls, and what renders the result.
-- This is the PORT under it -- the thing that actually runs the line -- and the pair is
-- the same split as `src/tools_fs.lua` over `double.fs`.
--
-- Called `shell` and never `bash`: it is eighteen commands and names which eighteen in
-- every refusal. A command it does not have is REFUSED BY NAME with the list, never
-- silently approximated.
--
-- Beyond isolation it buys DETERMINISM: the same script over the same filesystem produces
-- the same bytes every time -- listings sorted, no clock, no randomness, no environment.
--
-- It requires the grammar and the port contract, and nothing else. Contract: spec/shell.md.

local command = (function ()
  local ok, m = pcall(require, "command")
  if ok then return m end
  return require("src.command")
end)()

local port = (function ()
  local ok, m = pcall(require, "port")
  if ok then return m end
  return require("src.port")
end)()

local shell = {}

--- Bumped when a command changes what it answers.
shell.VOCABULARY = 1

-- small helpers

local function lines_of(text)
  local out = {}
  for line in tostring(text):gmatch("([^\n]*)\n?") do out[#out + 1] = line end
  -- The gmatch above yields one trailing empty for a text ending in a newline, and one
  -- for the empty string. Both are the same off-by-one and both are dropped here.
  if #out > 0 and out[#out] == "" then out[#out] = nil end
  return out
end

local function joined(list)
  if #list == 0 then return "" end
  return table.concat(list, "\n") .. "\n"
end

-- A glob, as a Lua pattern. `*` and `?` only, and a `*` does not cross a `/` -- which is
-- what `find -name` means and what every shell means by it.
local function globbed(pattern)
  local out = { "^" }
  for i = 1, #pattern do
    local ch = pattern:sub(i, i)
    if ch == "*" then out[#out + 1] = "[^/]*"
    elseif ch == "?" then out[#out + 1] = "[^/]"
    elseif ch:match("[%^%$%(%)%%%.%[%]%+%-]") then out[#out + 1] = "%" .. ch
    else out[#out + 1] = ch end
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

-- A path, resolved against the working directory and normalised. `..` is resolved
-- TEXTUALLY and then the result is checked, so a path that climbs out of the workspace is
-- refused by the same rule the filesystem port applies rather than by a second one that
-- could drift from it.
local function resolve(cwd, path)
  if type(path) ~= "string" or path == "" then return cwd end
  local whole = (path:sub(1, 1) == "/") and path:sub(2)
              or ((cwd == "") and path or (cwd .. "/" .. path))
  local parts = {}
  for part in whole:gmatch("[^/]+") do
    if part == "." then                     -- here
    elseif part == ".." then
      if #parts == 0 then return nil end    -- out of the workspace
      parts[#parts] = nil
    else
      parts[#parts + 1] = part
    end
  end
  local out = table.concat(parts, "/")
  if out ~= "" and not port.path_ok(out) then return nil end
  return out
end

-- Every file at or under a path, sorted. The one walk every recursive command shares.
local function under(fs, root)
  local out = {}
  local prefix = (root == "") and "" or (root .. "/")
  for p in pairs(fs.files) do
    if root == "" or p == root or p:sub(1, #prefix) == prefix then out[#out + 1] = p end
  end
  table.sort(out)
  return out
end

-- The commands: eighteen, and the list is the documentation. Each is
-- `(c, argv, stdin) -> code, out, err` where `c` is `{ fs = ..., cwd = ... }`. A command
-- that changes the working directory changes `c.cwd`, which is how `cd app && ls` works
-- and why a `cd` cannot escape its line.
--
-- Flags are read positionally and an unknown flag is an ERROR, never ignored.

local COMMANDS = {}

local function usage(name, said)
  return 2, "", name .. ": " .. said .. "\n"
end

-- Split argv into flags and operands, refusing any flag not in `known`.
local function split(argv, known, name)
  local flags, rest = {}, {}
  local only_operands = false
  for i = 2, #argv do
    local a = argv[i]
    if a == "--" then
      only_operands = true
    elseif not only_operands and #a > 1 and a:sub(1, 1) == "-" and a ~= "-" then
      if known[a] then
        flags[a] = true
      elseif a:sub(1, 2) ~= "--" then
        -- Bundled short flags: `-rf` is `-r` and `-f`.
        for j = 2, #a do
          local one = "-" .. a:sub(j, j)
          if not known[one] then return nil, one end
          flags[one] = true
        end
      else
        return nil, a
      end
    else
      rest[#rest + 1] = a
    end
  end
  local _ = name
  return flags, rest
end

COMMANDS["echo"] = function (_, argv)
  local words = {}
  for i = 2, #argv do words[#words + 1] = argv[i] end
  return 0, table.concat(words, " ") .. "\n", ""
end

COMMANDS["true"]  = function () return 0, "", "" end
COMMANDS["false"] = function () return 1, "", "" end
COMMANDS["pwd"]   = function (c) return 0, "/" .. c.cwd .. "\n", "" end

COMMANDS["cd"] = function (c, argv)
  local where = argv[2] or ""
  local at = resolve(c.cwd, where)
  if at == nil then return usage("cd", "that path leaves the workspace: " .. tostring(where)) end
  if at ~= "" and not c.fs.exists(at) then
    return 1, "", "cd: no such directory: " .. where .. "\n"
  end
  if c.fs.files[at] ~= nil then return 1, "", "cd: not a directory: " .. where .. "\n" end
  c.cwd = at
  return 0, "", ""
end

COMMANDS["ls"] = function (c, argv)
  -- `-a` and `-1` are accepted and change nothing, which is a fact about this
  -- filesystem rather than a shrug: nothing here is hidden, so `-a` has nothing extra to
  -- show, and the output is already one name per line. `spec/shell.md` says so, which
  -- makes it a promise rather than a coincidence somebody later relies on.
  local flags, rest = split(argv, { ["-a"] = true, ["-l"] = true, ["-1"] = true, ["-R"] = true }, "ls")
  if flags == nil then return usage("ls", "unknown option " .. rest) end
  local where = resolve(c.cwd, rest[1] or "")
  if where == nil then return usage("ls", "that path leaves the workspace") end
  -- A file names itself, exactly as it does everywhere else.
  if c.fs.files[where] ~= nil then return 0, (rest[1] or where) .. "\n", "" end
  if flags["-R"] then
    local out = under(c.fs, where)
    return 0, joined(out), ""
  end
  local entries, why = c.fs.list(where)
  if entries == nil then
    return 1, "", "ls: " .. ((type(why) == "table" and why.message) or "cannot list") .. "\n"
  end
  local out = {}
  for i = 1, #entries do
    if flags["-l"] then
      out[#out + 1] = string.format("%s %8d %s", entries[i].kind == "dir" and "d" or "-",
                                    entries[i].size or 0, entries[i].name)
    else
      out[#out + 1] = entries[i].name
    end
  end
  return 0, joined(out), ""
end

COMMANDS["cat"] = function (c, argv, stdin)
  local _, rest = split(argv, {}, "cat")
  if #rest == 0 then return 0, stdin or "", "" end
  local out, code, err = {}, 0, {}
  for i = 1, #rest do
    local at = resolve(c.cwd, rest[i])
    local text = at and c.fs.read(at) or nil
    if text == nil then
      code = 1
      err[#err + 1] = "cat: " .. rest[i] .. ": no such file"
    else
      out[#out + 1] = text
    end
  end
  return code, table.concat(out), joined(err)
end

COMMANDS["touch"] = function (c, argv)
  local _, rest = split(argv, {}, "touch")
  if #rest == 0 then return usage("touch", "needs a path") end
  for i = 1, #rest do
    local at = resolve(c.cwd, rest[i])
    if at == nil then return usage("touch", "that path leaves the workspace: " .. rest[i]) end
    if c.fs.files[at] == nil then
      local ok, why = c.fs.write(at, "")
      if not ok then return 1, "", "touch: " .. ((type(why) == "table" and why.message) or "cannot write") .. "\n" end
    end
  end
  return 0, "", ""
end

COMMANDS["mkdir"] = function (c, argv)
  local flags, rest = split(argv, { ["-p"] = true }, "mkdir")
  if flags == nil then return usage("mkdir", "unknown option " .. rest) end
  if #rest == 0 then return usage("mkdir", "needs a path") end
  for i = 1, #rest do
    local at = resolve(c.cwd, rest[i])
    if at == nil then return usage("mkdir", "that path leaves the workspace: " .. rest[i]) end
    if c.fs.exists(at) and not flags["-p"] then
      return 1, "", "mkdir: already exists: " .. rest[i] .. "\n"
    end
    if c.fs.readonly then return 1, "", "mkdir: the filesystem is read-only\n" end
    c.fs.dirs[at] = true
  end
  return 0, "", ""
end

COMMANDS["rm"] = function (c, argv)
  local flags, rest = split(argv, { ["-r"] = true, ["-f"] = true, ["-R"] = true }, "rm")
  if flags == nil then return usage("rm", "unknown option " .. rest) end
  if #rest == 0 then return usage("rm", "needs a path") end
  local recursive = flags["-r"] or flags["-R"]
  local code, err = 0, {}
  for i = 1, #rest do
    local at = resolve(c.cwd, rest[i])
    if at == nil then
      code = 1; err[#err + 1] = "rm: that path leaves the workspace: " .. rest[i]
    elseif c.fs.files[at] ~= nil then
      local ok, why = c.fs.remove(at)
      if not ok and not flags["-f"] then
        code = 1
        err[#err + 1] = "rm: " .. ((type(why) == "table" and why.message) or "cannot remove")
      end
    elseif c.fs.exists(at) then
      if not recursive then
        code = 1; err[#err + 1] = "rm: is a directory: " .. rest[i]
      else
        local kids = under(c.fs, at)
        for k = 1, #kids do c.fs.remove(kids[k]) end
        for d in pairs(c.fs.dirs) do
          if d == at or d:sub(1, #at + 1) == at .. "/" then c.fs.dirs[d] = nil end
        end
      end
    elseif not flags["-f"] then
      code = 1; err[#err + 1] = "rm: no such file: " .. rest[i]
    end
  end
  return code, "", joined(err)
end

local function copy_one(c, from, to, name)
  local at = resolve(c.cwd, from)
  local into = resolve(c.cwd, to)
  if at == nil or into == nil then
    return 1, name .. ": that path leaves the workspace"
  end
  local text = c.fs.read(at)
  if text == nil then return 1, name .. ": no such file: " .. from end
  -- A destination that is a directory takes the source's basename, as everywhere.
  if into ~= "" and c.fs.files[into] == nil and c.fs.exists(into) then
    into = into .. "/" .. (at:match("([^/]+)$") or at)
  end
  local ok, why = c.fs.write(into, text)
  if not ok then
    return 1, name .. ": " .. ((type(why) == "table" and why.message) or "cannot write")
  end
  return 0, nil, at
end

COMMANDS["cp"] = function (c, argv)
  local flags, rest = split(argv, { ["-r"] = true, ["-R"] = true }, "cp")
  if flags == nil then return usage("cp", "unknown option " .. rest) end
  if #rest ~= 2 then return usage("cp", "takes a source and a destination") end

  local from = resolve(c.cwd, rest[1])
  if from == nil then return 1, "", "cp: that path leaves the workspace: " .. rest[1] .. "\n" end

  -- A directory. `-r` COPIES IT, and without `-r` cp says no. Accepting the flag and
  -- copying nothing is the exact failure this shell's contract bans, and it is worse than
  -- not having the flag at all, because it reports success.
  if c.fs.files[from] == nil and c.fs.exists(from) then
    if not (flags["-r"] or flags["-R"]) then
      return 1, "", "cp: is a directory: " .. rest[1] .. " (use -r)\n"
    end
    local into = resolve(c.cwd, rest[2])
    if into == nil then return 1, "", "cp: that path leaves the workspace: " .. rest[2] .. "\n" end
    local kids = under(c.fs, from)
    if #kids == 0 then return 1, "", "cp: nothing to copy from " .. rest[1] .. "\n" end
    for i = 1, #kids do
      local tail = kids[i]:sub(#from + 2)
      local ok, why = c.fs.write((into == "" and tail) or (into .. "/" .. tail), c.fs.read(kids[i]))
      if not ok then
        return 1, "", "cp: " .. ((type(why) == "table" and why.message) or "cannot write") .. "\n"
      end
    end
    return 0, "", ""
  end

  local code, why = copy_one(c, rest[1], rest[2], "cp")
  return code, "", why and (why .. "\n") or ""
end

COMMANDS["mv"] = function (c, argv)
  local _, rest = split(argv, {}, "mv")
  if #rest ~= 2 then return usage("mv", "takes a source and a destination") end
  local code, why, from = copy_one(c, rest[1], rest[2], "mv")
  if code ~= 0 then return code, "", why .. "\n" end
  c.fs.remove(from)
  return 0, "", ""
end

COMMANDS["wc"] = function (c, argv, stdin)
  local flags, rest = split(argv, { ["-l"] = true, ["-w"] = true, ["-c"] = true }, "wc")
  if flags == nil then return usage("wc", "unknown option " .. rest) end
  local function count(text, label)
    local l = #lines_of(text)
    local w = 0
    for _ in text:gmatch("%S+") do w = w + 1 end
    local parts = {}
    if flags["-l"] or not (flags["-w"] or flags["-c"]) then parts[#parts + 1] = tostring(l) end
    if flags["-w"] or not (flags["-l"] or flags["-c"]) then parts[#parts + 1] = tostring(w) end
    if flags["-c"] or not (flags["-l"] or flags["-w"]) then parts[#parts + 1] = tostring(#text) end
    if label then parts[#parts + 1] = label end
    return table.concat(parts, " ")
  end
  if #rest == 0 then return 0, count(stdin or "") .. "\n", "" end
  local out, code, err = {}, 0, {}
  for i = 1, #rest do
    local at = resolve(c.cwd, rest[i])
    local text = at and c.fs.read(at) or nil
    if text == nil then code = 1; err[#err + 1] = "wc: " .. rest[i] .. ": no such file"
    else out[#out + 1] = count(text, rest[i]) end
  end
  return code, joined(out), joined(err)
end

local function ends(c, argv, stdin, name)
  local n, rest = 10, {}
  local i = 2
  while i <= #argv do
    if argv[i] == "-n" and argv[i + 1] then
      n = tonumber(argv[i + 1]) or n
      i = i + 2
    elseif argv[i]:match("^%-%d+$") then
      n = tonumber(argv[i]:sub(2)) or n
      i = i + 1
    elseif argv[i]:sub(1, 1) == "-" and #argv[i] > 1 then
      return usage(name, "unknown option " .. argv[i])
    else
      rest[#rest + 1] = argv[i]
      i = i + 1
    end
  end
  local text = stdin or ""
  if #rest > 0 then
    local at = resolve(c.cwd, rest[1])
    text = at and c.fs.read(at) or nil
    if text == nil then return 1, "", name .. ": " .. rest[1] .. ": no such file\n" end
  end
  local all = lines_of(text)
  local out = {}
  if name == "head" then
    for k = 1, math.min(n, #all) do out[#out + 1] = all[k] end
  else
    for k = math.max(1, #all - n + 1), #all do out[#out + 1] = all[k] end
  end
  return 0, joined(out), ""
end

COMMANDS["head"] = function (c, argv, stdin) return ends(c, argv, stdin, "head") end
COMMANDS["tail"] = function (c, argv, stdin) return ends(c, argv, stdin, "tail") end

COMMANDS["sort"] = function (c, argv, stdin)
  local flags, rest = split(argv, { ["-r"] = true, ["-u"] = true }, "sort")
  if flags == nil then return usage("sort", "unknown option " .. rest) end
  local text = stdin or ""
  if #rest > 0 then
    local at = resolve(c.cwd, rest[1])
    text = at and c.fs.read(at) or nil
    if text == nil then return 1, "", "sort: " .. rest[1] .. ": no such file\n" end
  end
  local all = lines_of(text)
  table.sort(all)
  if flags["-r"] then
    local back = {}
    for i = #all, 1, -1 do back[#back + 1] = all[i] end
    all = back
  end
  if flags["-u"] then
    local seen, out = {}, {}
    for i = 1, #all do
      if not seen[all[i]] then seen[all[i]] = true; out[#out + 1] = all[i] end
    end
    all = out
  end
  return 0, joined(all), ""
end

COMMANDS["grep"] = function (c, argv, stdin)
  local flags, rest = split(argv, { ["-i"] = true, ["-n"] = true, ["-r"] = true, ["-l"] = true,
                                    ["-v"] = true, ["-c"] = true, ["-R"] = true }, "grep")
  if flags == nil then return usage("grep", "unknown option " .. rest) end
  if #rest == 0 then return usage("grep", "needs a pattern") end
  -- A FIXED STRING, not a regular expression. Lua patterns are not POSIX ones and a
  -- shell that accepted `\d` and matched a literal d would be lying about what it did.
  -- `spec/shell.md` says so; a caller wanting more is refused rather than approximated.
  local needle = rest[1]
  local function hit(line)
    local a, b = line, needle
    if flags["-i"] then a, b = line:lower(), needle:lower() end
    local found = a:find(b, 1, true) ~= nil
    if flags["-v"] then return not found end
    return found
  end

  local paths, walked = {}, false
  for i = 2, #rest do
    local at = resolve(c.cwd, rest[i])
    if at == nil then return usage("grep", "that path leaves the workspace: " .. rest[i]) end
    if (flags["-r"] or flags["-R"]) and c.fs.files[at] == nil then
      walked = true
      local kids = under(c.fs, at)
      for k = 1, #kids do paths[#paths + 1] = kids[k] end
    else
      paths[#paths + 1] = at
    end
  end
  -- A walk always names the file, even when it found one: `grep -r` over a directory
  -- that happens to hold a single file must not read differently from one that holds two.
  local label = walked or #paths > 1

  local out, found = {}, false
  if #paths == 0 then
    local all = lines_of(stdin or "")
    local n = 0
    for i = 1, #all do
      if hit(all[i]) then
        found = true; n = n + 1
        if not flags["-c"] then out[#out + 1] = flags["-n"] and (i .. ":" .. all[i]) or all[i] end
      end
    end
    if flags["-c"] then out[#out + 1] = tostring(n) end
  else
    for p = 1, #paths do
      local text = c.fs.read(paths[p])
      if text ~= nil then
        local all, n = lines_of(text), 0
        for i = 1, #all do
          if hit(all[i]) then
            found = true; n = n + 1
            if flags["-l"] then break end
            if not flags["-c"] then
              local head = label and (paths[p] .. ":") or ""
              out[#out + 1] = head .. (flags["-n"] and (i .. ":") or "") .. all[i]
            end
          end
        end
        if flags["-l"] and n > 0 then out[#out + 1] = paths[p] end
        if flags["-c"] then out[#out + 1] = (label and (paths[p] .. ":") or "") .. n end
      end
    end
  end
  -- grep's exit code is its answer: 1 means it found nothing, and `grep x f && ...` is
  -- the idiom that depends on it.
  return found and 0 or 1, joined(out), ""
end

COMMANDS["find"] = function (c, argv)
  local where, glob = nil, nil
  local i = 2
  while i <= #argv do
    if argv[i] == "-name" and argv[i + 1] then
      glob = argv[i + 1]; i = i + 2
    elseif argv[i] == "-type" and argv[i + 1] then
      i = i + 2                                   -- accepted and ignored: everything is a file
    elseif argv[i]:sub(1, 1) == "-" then
      return usage("find", "unknown option " .. argv[i])
    else
      where = where or argv[i]; i = i + 1
    end
  end
  local root = resolve(c.cwd, where or "")
  if root == nil then return usage("find", "that path leaves the workspace") end
  local all = under(c.fs, root)
  local out = {}
  for k = 1, #all do
    local base = all[k]:match("([^/]+)$") or all[k]
    if glob == nil or base:match(globbed(glob)) then out[#out + 1] = all[k] end
  end
  return 0, joined(out), ""
end

--- The commands this shell has, as a fresh sorted list on every read.
function shell.commands()
  local out = {}
  for name in pairs(COMMANDS) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Does this shell have that command?
function shell.has(name)
  return COMMANDS[name] ~= nil
end

-- running a line

-- One simple command, with its redirections. `stdin` is what the pipe before it wrote.
local function run_simple(c, simple, stdin)
  local argv = simple.argv
  if #argv == 0 then return 0, "", "" end

  -- An assignment prefix is accepted and has no effect: this shell has no environment,
  -- and pretending `FOO=bar cmd` set something would be a lie a script could depend on.
  local at = 1
  while type(argv[at]) == "string" and argv[at]:match("^[%w_]+=") do at = at + 1 end
  if at > #argv then return 0, "", "" end
  local trimmed = {}
  for i = at, #argv do trimmed[#trimmed + 1] = argv[i] end

  -- `<` before the command runs: the file is this command's input.
  for i = 1, #(simple.redirects or {}) do
    local r = simple.redirects[i]
    if r.op == "<" then
      local from = resolve(c.cwd, r.target)
      local text = from and c.fs.read(from) or nil
      if text == nil then
        return 1, "", "shell: no such file: " .. tostring(r.target) .. "\n"
      end
      stdin = text
    end
  end

  local name = trimmed[1]
  local body = COMMANDS[name]
  if body == nil then
    -- Refused by name. A shell of twelve commands that says which twelve is a shell a
    -- model can work with; one that fails vaguely teaches it to retry the same thing.
    return 127, "", string.format("shell: no such command: %s (this shell has: %s)\n",
                                  tostring(name), table.concat(shell.commands(), ", "))
  end

  local code, out, err = body(c, trimmed, stdin)
  out, err = out or "", err or ""

  for i = 1, #(simple.redirects or {}) do
    local r = simple.redirects[i]
    if r.op == ">" or r.op == ">>" then
      local into = resolve(c.cwd, r.target)
      if into == nil then
        return 1, "", "shell: that path leaves the workspace: " .. tostring(r.target) .. "\n"
      end
      local text = out
      if r.op == ">>" then text = (c.fs.read(into) or "") .. out end
      local ok, why = c.fs.write(into, text)
      if not ok then
        return 1, "", "shell: " .. ((type(why) == "table" and why.message) or "cannot write") .. "\n"
      end
      out = ""
    end
  end
  return code, out, err
end

--- One command line, run against a filesystem.
---
--- Answers `{ code, out, err }`. A line the grammar cannot place is a result with a
--- non-zero code and a sentence, never a raise: a malformed command is a thing that
--- happened, and rule 4 says a thing that happened comes back as a result.
function shell.line(fs, text, cwd)
  if type(text) ~= "string" then
    error("shell.line(fs, text): text is a string, and arrived as " .. type(text), 2)
  end
  local parsed, why, where = command.parse(text)
  if not parsed then
    return { code = 2, out = "",
             err = string.format("shell: %s at byte %d\n", tostring(why), tonumber(where) or 0) }
  end

  local c = { fs = fs, cwd = cwd or "" }
  local out, err, code = {}, {}, 0
  local piped = nil
  local i = 1
  while i <= #parsed do
    local simple = parsed[i]
    local this_code, this_out, this_err = run_simple(c, simple, piped)
    err[#err + 1] = this_err
    code = this_code

    if simple.joined == "|" then
      -- Into the next command, not onto the output. A pipeline's exit code is the last
      -- command's, which is what `grep x f | wc -l` depends on.
      piped = this_out
      i = i + 1
    else
      piped = nil
      out[#out + 1] = this_out
      if simple.joined == "&&" and code ~= 0 then
        -- Skip to the next command that is not itself chained by `&&`.
        while i <= #parsed and parsed[i].joined == "&&" do i = i + 1 end
        i = i + 1
      elseif simple.joined == "||" and code == 0 then
        while i <= #parsed and parsed[i].joined == "||" do i = i + 1 end
        i = i + 1
      else
        i = i + 1
      end
    end
  end
  return { code = code, out = table.concat(out), err = table.concat(err), cwd = c.cwd }
end

--- A shell PORT over a filesystem: what `spec/port.md` calls `p.sh`.
---
--- `{ "sh", "-c", line }` runs the line. Any other argv is one simple command, run
--- directly, which is what the port contract says argv means.
function shell.port(fs, opts)
  if type(fs) ~= "table" or type(fs.read) ~= "function" then
    error("shell.port(fs): fs is a filesystem port, and arrived as " .. type(fs), 2)
  end
  opts = opts or {}
  local s = { ran = {}, fs = fs }

  function s.run(argv, o)
    port.shape.argv("sh.run", argv)
    port.shape.opts("sh.run", o)
    s.ran[#s.ran + 1] = { argv = argv, opts = o }

    local cwd = ""
    if o ~= nil and o.cwd ~= nil then
      if not port.path_ok(o.cwd) then
        return nil, port.error("sh", "run", "denied",
          o.cwd == "" and "the working directory is the empty string; omit `cwd` for the workspace root"
                       or ("that working directory leaves the workspace: " .. o.cwd))
      end
      cwd = o.cwd
    end

    local line
    if (argv[1] == "sh" or argv[1] == "bash") and argv[2] == "-c" and type(argv[3]) == "string" then
      line = argv[3]
    else
      -- A direct argv, quoted back into a line so one grammar reads every path into this
      -- shell. Quoting here rather than executing argv directly means `{"grep","a b","f"}`
      -- and `sh -c 'grep "a b" f'` cannot come apart.
      local parts = {}
      for i = 1, #argv do
        parts[#parts + 1] = argv[i]:find("[%s'\"\\]") and ('"' .. argv[i]:gsub('[\\"]', "\\%0") .. '"')
                            or argv[i]
      end
      line = table.concat(parts, " ")
    end

    local r = shell.line(fs, line, cwd)
    if r.code == 127 and opts.strict then
      -- A host that would rather a missing command be an error than an exit code. Off by
      -- default, because `spec/port.md` is explicit that a non-zero exit is a RESULT.
      return nil, port.error("sh", "run", "not_found", (r.err:gsub("\n$", "")))
    end
    return { code = r.code, out = r.out, err = r.err, timed_out = false }
  end

  return s
end

return shell
