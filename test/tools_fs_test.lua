-- tools_fs — the tests. Every one runs against a fake filesystem port: a table of
-- path to string, plus a set of empty directories, plus whatever failure the test
-- wants injected. No disk, no clock, no subprocess.
--
-- Returns a table of named functions. Each asserts with plain `assert` and prints
-- nothing when it passes.

local here = debug.getinfo(1, "S").source
here = string.sub(here, 1, 1) == "@" and string.sub(here, 2) or here
local root = string.match(here, "^(.*)/test/[^/]+$") or "."

package.path = root .. "/src/?.lua;" .. package.path

local function load_src(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  local f = loadfile(root .. "/src/" .. name .. ".lua")
  if f then return f() end
  error("cannot load " .. name .. ": " .. tostring(mod))
end

local tools_fs = load_src "tools_fs"
local spec     = load_src "spec"

-- ------------------------------------------------------------------ the fakes

local function err(call, code, message)
  return { port = "fs", call = call, code = code, message = message }
end

local function dirs_of(f)
  local d = { [""] = true }
  for p in pairs(f.files) do
    local parts = {}
    for seg in string.gmatch(p, "[^/]+") do parts[#parts + 1] = seg end
    local acc = ""
    for i = 1, #parts - 1 do
      acc = (acc == "" and parts[i]) or (acc .. "/" .. parts[i])
      d[acc] = true
    end
  end
  for i = 1, #f.empty do d[f.empty[i]] = true end
  return d
end

-- `files` maps a workspace-relative path to its bytes. `cfg.empty` is a list of
-- directories with nothing in them, `cfg.links` a set of paths the port calls a link,
-- `cfg.raise` a set of call names that raise, `cfg.write_err` an error write returns.
local function fs_double(files, cfg)
  cfg = cfg or {}
  local f = {
    files = {}, wrote = {}, listed = {}, read_calls = {},
    empty = cfg.empty or {}, links = cfg.links or {},
    readonly = cfg.readonly or false, flip = 0,
  }
  for k, v in pairs(files or {}) do f.files[k] = v end

  local function raises(name) return cfg.raise and cfg.raise[name] end

  function f.read(path)
    if raises "read" then error("the fake read blew up") end
    f.read_calls[#f.read_calls + 1] = path
    local v = f.files[path]
    if v == nil then return nil, err("read", "not_found", "no such file: " .. path) end
    if cfg.cap and #v > cfg.cap then return nil, err("read", "too_big", "over the cap: " .. path) end
    return v
  end

  function f.write(path, text)
    if raises "write" then error("the fake write blew up") end
    if f.readonly then return nil, err("write", "denied", "the workspace is read-only") end
    if cfg.write_err then return nil, cfg.write_err end
    f.wrote[#f.wrote + 1] = { path = path, text = text }
    f.files[path] = text
    return true
  end

  function f.remove(path)
    f.files[path] = nil
    return true
  end

  function f.exists(path)
    if f.files[path] ~= nil then return true end
    return dirs_of(f)[path] == true
  end

  function f.list(dir)
    if raises "list" then error("the fake list blew up") end
    f.listed[#f.listed + 1] = dir
    if cfg.on_list then cfg.on_list(f, dir) end
    local d = dirs_of(f)
    if not d[dir] then return nil, err("list", "not_found", "no such directory: " .. dir) end
    local seen, out = {}, {}
    local function add(name, kind, size)
      if seen[name] then return end
      seen[name] = true
      out[#out + 1] = { name = name, kind = kind, size = size }
    end
    for p, text in pairs(f.files) do
      local rest = nil
      if dir == "" then rest = p
      elseif string.sub(p, 1, #dir + 1) == dir .. "/" then rest = string.sub(p, #dir + 2) end
      if rest and rest ~= "" then
        local cut = string.find(rest, "/", 1, true)
        if cut then
          local child = string.sub(rest, 1, cut - 1)
          local full = (dir == "" and child) or (dir .. "/" .. child)
          add(child, f.links[full] and "link" or "dir", nil)
        else
          add(rest, f.links[p] and "link" or "file", #text)
        end
      end
    end
    for i = 1, #f.empty do
      local p = f.empty[i]
      local rest = nil
      if dir == "" then rest = p
      elseif string.sub(p, 1, #dir + 1) == dir .. "/" then rest = string.sub(p, #dir + 2) end
      if rest and rest ~= "" and not string.find(rest, "/", 1, true) then
        add(rest, f.links[p] and "link" or "dir", nil)
      end
    end
    -- Two runs must agree, so the port hands them back in a different order each time.
    f.flip = f.flip + 1
    table.sort(out, function (a, b)
      if f.flip % 2 == 0 then return a.name < b.name end
      return a.name > b.name
    end)
    return out
  end

  return f
end

local function clock_double(at)
  local c = { t = at or 0 }
  function c.now() return c.t end
  function c.mono() return c.t end
  function c.sleep() return true end
  return c
end

-- The public prefix, over the real declaration surface in src/spec.lua.
local function agent_double()
  local a = spec.new()
  local g = { declared = a }
  g.tool = function (name)
    return function (t) return spec.add_tool(a, name, t) end
  end
  for k, v in pairs(spec.types) do g[k] = v end
  return g
end

-- One workspace, installed, with a way to call a tool body the way a turn would.
local function setup(files, opts, cfg)
  opts = opts or {}
  local fs = fs_double(files, cfg)
  local clock = clock_double(0)
  local o = { port = { fs = fs, clock = clock } }
  for k, v in pairs(opts) do o[k] = v end
  local g = agent_double()
  local installed = tools_fs.install(g, o)
  local w = { fs = fs, clock = clock, agent = g, installed = installed }
  function w.call(name, args)
    local tool = g.declared.tools[installed.tools[name] or name]
    assert(tool, "no tool named " .. tostring(name))
    return tool.run { args = args or {}, fs = fs, clock = clock, step = 1, call = "c1" }
  end
  return w
end

local function is_failure(r)
  return type(r) == "table" and r.ok == false and type(r.code) == "string"
     and type(r.reason) == "string" and r.reason ~= ""
end

local T = {}

-- ------------------------------------------------------------------ declaration

function T.install_declares_six_tools()
  local w = setup {}
  local schema = spec.schema(w.agent.declared)
  local want = { "read", "write", "edit", "list", "glob", "search" }
  assert(#schema == 6, "six tools, got " .. #schema)
  for i = 1, 6 do
    assert(schema[i].name == want[i], "tool " .. i .. " is " .. schema[i].name)
    assert(type(schema[i].about) == "string" and schema[i].about ~= "", "no about on " .. schema[i].name)
  end
end

function T.install_runs_nothing()
  local blows = {}
  local names = { "read", "write", "list", "remove", "exists" }
  for i = 1, #names do blows[names[i]] = function () error("a port call ran at declaration") end end
  local g = agent_double()
  local installed = tools_fs.install(g, { root = "/w", port = { fs = blows } })
  assert(installed.tools.read == "read")
  assert(#spec.schema(g.declared) == 6)
end

function T.install_refuses_a_bad_root()
  local g = agent_double()
  local ok, message = pcall(tools_fs.install, g, { root = 7, port = { fs = fs_double {} } })
  assert(not ok, "a number root was accepted")
  assert(string.find(message, "root", 1, true), "the message does not name root: " .. tostring(message))
end

function T.install_refuses_a_port_missing_a_call()
  local fs = fs_double {}
  fs.write = nil
  local g = agent_double()
  local ok, message = pcall(tools_fs.install, g, { root = "/w", port = { fs = fs } })
  assert(not ok, "a port with no write was accepted")
  assert(string.find(message, "write", 1, true), "the message does not name write: " .. tostring(message))
end

function T.install_refuses_a_bad_deny_pattern()
  local g = agent_double()
  local ok, message = pcall(tools_fs.install, g, { port = { fs = fs_double {} }, deny = { "src/{a,b}" } })
  assert(not ok, "a brace pattern was accepted as a deny rule")
  assert(string.find(message, "deny", 1, true))
end

function T.installing_twice_is_refused()
  local g = agent_double()
  local fs = fs_double {}
  tools_fs.install(g, { port = { fs = fs } })
  local ok, message = pcall(tools_fs.install, g, { port = { fs = fs } })
  assert(not ok, "the same tool was declared twice")
  assert(string.find(message, "twice", 1, true), "the message is " .. tostring(message))
end

function T.renamed_tools_keep_their_contract()
  local w = setup({ ["a.txt"] = "hi" }, { names = { read = "fs_read" } })
  assert(w.installed.tools.read == "fs_read")
  assert(w.agent.declared.tools["fs_read"], "fs_read was not declared")
  assert(not w.agent.declared.tools["read"], "read was declared as well")
  local r = w.call("read", { path = "a.txt" })
  assert(r.ok and r.text == "hi")
end

function T.write_and_edit_ask_by_default()
  local w = setup {}
  local ask = {}
  local schema = spec.schema(w.agent.declared)
  for i = 1, #schema do ask[schema[i].name] = schema[i].ask end
  assert(ask.write == true and ask.edit == true, "write and edit do not ask")
  assert(ask.read == false and ask.list == false and ask.glob == false and ask.search == false,
    "a reading tool asks")
end

-- ------------------------------------------------------------------ reading

function T.read_returns_bytes_verbatim()
  local body = "one\ttab\r\ntwo\r\nthree"
  local w = setup { ["a.txt"] = body }
  local r = w.call("read", { path = "a.txt" })
  assert(r.ok, r.reason)
  assert(r.text == body, "the bytes changed")
  assert(r.bytes == #body)
  assert(r.lines == 3 and r.from_line == 1 and r.to_line == 3 and r.eof == true)
  assert(not string.find(r.text, "1:", 1, true), "a line number was interleaved")
end

function T.read_of_an_empty_file_succeeds()
  local w = setup { ["e.txt"] = "" }
  local r = w.call("read", { path = "e.txt" })
  assert(r.ok and r.text == "" and r.lines == 0 and r.eof == true)
end

function T.read_offset_past_the_end_is_empty_not_an_error()
  local w = setup { ["a.txt"] = "1\n2\n3\n" }
  local r = w.call("read", { path = "a.txt", offset = 999 })
  assert(r.ok, "an offset past the end was an error")
  assert(r.text == "" and r.lines == 0 and r.eof == true)
end

function T.read_a_slice_keeps_its_place()
  local w = setup { ["a.txt"] = "1\n2\n3\n4\n5\n" }
  local r = w.call("read", { path = "a.txt", offset = 2, limit = 2 })
  assert(r.ok and r.text == "2\n3\n", "slice is " .. string.format("%q", r.text))
  assert(r.from_line == 2 and r.to_line == 3 and r.eof == false and r.lines == 2)
end

function T.read_of_a_missing_file_says_not_found()
  local w = setup({ ["a.txt"] = "x" }, { root = "/w/project" })
  local r = w.call("read", { path = "b.txt" })
  assert(is_failure(r) and r.code == "not_found", "code is " .. tostring(r.code))
  assert(string.find(r.reason, "b.txt", 1, true), "the reason does not name the file")
  assert(not string.find(r.reason, "/w/project", 1, true), "the reason leaks the host path")
end

function T.read_of_a_directory_says_not_a_file()
  local w = setup { ["src/a.lua"] = "x" }
  local r = w.call("read", { path = "src" })
  assert(is_failure(r) and r.code == "not_a_file", "code is " .. tostring(r.code))
  assert(r.kind == "dir")
end

function T.read_over_max_bytes_refuses_with_the_size()
  local w = setup({ ["big.txt"] = string.rep("x", 100) }, { max_bytes = 20 })
  local r = w.call("read", { path = "big.txt" })
  assert(is_failure(r) and r.code == "too_large")
  assert(r.size == 100 and r.limit == 20)
  assert(string.find(r.reason, "offset", 1, true) and string.find(r.reason, "limit", 1, true),
    "the reason does not suggest offset and limit")
end

function T.read_of_a_binary_file_refuses()
  local body = "ab\0cdef"
  local w = setup { ["b.bin"] = body }
  local r = w.call("read", { path = "b.bin" })
  assert(is_failure(r) and r.code == "binary", "code is " .. tostring(r.code))
  assert(r.size == #body)
  assert(not string.find(r.reason, "cdef", 1, true), "the bytes came back in the reason")
  assert(r.text == nil, "a binary file returned text")
end

-- ------------------------------------------------------------------ path safety

function T.a_climbing_path_is_refused()
  local w = setup { ["a.txt"] = "x" }
  local tries = { "../secrets", "a/../../secrets", "./../x" }
  for i = 1, #tries do
    local r = w.call("read", { path = tries[i] })
    assert(is_failure(r) and r.code == "outside_workspace", tries[i] .. " gave " .. tostring(r.code))
  end
  assert(#w.fs.read_calls == 0, "a climbing path reached the port")
  assert(#w.fs.listed == 0, "a climbing path reached the port")
end

function T.an_absolute_path_is_refused_with_a_suggestion()
  local w = setup({ ["a.txt"] = "x" }, { root = "/w/project" })
  local inside = w.call("read", { path = "/w/project/src/a.lua" })
  assert(is_failure(inside) and inside.code == "outside_workspace")
  assert(inside.suggest == "src/a.lua", "suggest is " .. tostring(inside.suggest))
  local outside = w.call("read", { path = "/etc/passwd" })
  assert(is_failure(outside) and outside.code == "outside_workspace")
  assert(outside.suggest == nil, "a path outside the root got a suggestion")
end

function T.a_backslash_is_not_a_separator()
  local abs, rel = tools_fs.resolve("/w", "..\\..\\etc\\passwd")
  assert(rel == "..\\..\\etc\\passwd", "a backslash split the path: " .. tostring(rel))
  assert(abs == "/w/..\\..\\etc\\passwd")
  local w = setup { ["a.txt"] = "x" }
  local r = w.call("read", { path = "..\\..\\etc\\passwd" })
  assert(is_failure(r), "it was not refused")
  assert(r.code ~= "outside_workspace", "one filename was read as an escape")
end

function T.a_zero_byte_in_a_path_is_refused()
  local w = setup { ["a.txt"] = "x" }
  local r = w.call("read", { path = "a\0b" })
  assert(is_failure(r) and r.code == "outside_workspace", "code is " .. tostring(r.code))
  assert(#w.fs.read_calls == 0, "a zero byte reached the port")
end

function T.a_tilde_is_a_filename()
  local _, rel = tools_fs.resolve("/w", "~/x")
  assert(rel == "~/x", "a tilde was expanded: " .. tostring(rel))
  local _, bare = tools_fs.resolve("/w", "~")
  assert(bare == "~")
end

function T.a_deny_pattern_refuses_every_tool()
  local files = { [".git/config"] = "[core]", ["src/a.lua"] = "x" }
  local w = setup(files, { deny = { ".git/**" } })
  local calls = {
    { "read",   { path = ".git/config" } },
    { "write",  { path = ".git/config", text = "x" } },
    { "edit",   { path = ".git/config", old = "a", new = "b" } },
    { "list",   { path = ".git/config" } },
    { "glob",   { pattern = "*", path = ".git/config" } },
    { "search", { pattern = "core", path = ".git/config" } },
  }
  for i = 1, #calls do
    local r = w.call(calls[i][1], calls[i][2])
    assert(is_failure(r) and r.code == "denied", calls[i][1] .. " gave " .. tostring(r.code))
    assert(r.pattern == ".git/**")
  end
  -- `**` matches zero segments, so a rule ending in it covers the directory itself
  local dir = w.call("list", { path = ".git" })
  assert(is_failure(dir) and dir.code == "denied", "the denied directory itself listed")
  local g = w.call("glob", { pattern = "**/*" })
  assert(g.ok, g.reason)
  for i = 1, #g.paths do
    assert(not string.find(g.paths[i], ".git", 1, true), "a denied path came back: " .. g.paths[i])
  end
  assert(#g.paths == 1 and g.paths[1] == "src/a.lua")
end

function T.a_link_is_never_followed()
  local files = { ["a/real.txt"] = "x", ["a/link/inside.txt"] = "y" }
  local w = setup(files, {}, { links = { ["a/link"] = true } })
  local r = w.call("list", { path = "a", depth = 5 })
  assert(r.ok, r.reason)
  local kinds = {}
  for i = 1, #r.entries do kinds[r.entries[i].path] = r.entries[i].kind end
  assert(kinds["a/real.txt"] == "file")
  assert(kinds["a/link"] == "link", "the link is " .. tostring(kinds["a/link"]))
  assert(kinds["a/link/inside.txt"] == nil, "the walk descended into a link")
end

function T.resolve_is_pure()
  local abs, rel = tools_fs.resolve("/w", "./src/../src/a.lua")
  assert(abs == "/w/src/a.lua" and rel == "src/a.lua")
  local a2, code = tools_fs.resolve("/w", "../x")
  assert(a2 == nil and code == "outside_workspace")
  local a3, code3 = tools_fs.resolve("/w", 7)
  assert(a3 == nil and code3 == "bad_args")
  local a4, rel4 = tools_fs.resolve("", "a/b")
  assert(a4 == "a/b" and rel4 == "a/b")
  local a5, rel5 = tools_fs.resolve("/w/", "")
  assert(a5 == "/w" and rel5 == "")
end

-- ------------------------------------------------------------------ editing

function T.edit_replaces_one_occurrence()
  local w = setup { ["a.lua"] = "local x = 1\nreturn x\n" }
  local r = w.call("edit", { path = "a.lua", old = "local x = 1", new = "local x = 2" })
  assert(r.ok, r.reason)
  assert(r.replaced == 1 and r.line == 1)
  assert(#w.fs.wrote == 1, "the port saw " .. #w.fs.wrote .. " writes")
  assert(w.fs.wrote[1].text == "local x = 2\nreturn x\n")
end

function T.edit_refuses_two_occurrences()
  local w = setup { ["a.lua"] = "x = 1\ny = 2\nx = 1\n" }
  local r = w.call("edit", { path = "a.lua", old = "x = 1", new = "x = 3" })
  assert(is_failure(r) and r.code == "ambiguous", "code is " .. tostring(r.code))
  assert(r.count == 2)
  assert(r.lines[1] == 1 and r.lines[2] == 3, "the lines are wrong")
  assert(#w.fs.wrote == 0, "an ambiguous edit wrote")
end

function T.edit_with_expect_replaces_them_all()
  local body = "a\na\na\n"
  local w = setup { ["a.txt"] = body }
  local r = w.call("edit", { path = "a.txt", old = "a", new = "b", expect = 3 })
  assert(r.ok, r.reason)
  assert(r.replaced == 3)
  assert(#w.fs.wrote == 1 and w.fs.wrote[1].text == "b\nb\nb\n")

  local w2 = setup { ["a.txt"] = body }
  local r2 = w2.call("edit", { path = "a.txt", old = "a", new = "b", expect = 2 })
  assert(is_failure(r2) and r2.code == "ambiguous" and r2.count == 3)
  assert(#w2.fs.wrote == 0, "a wrong expect wrote")
end

function T.edit_refuses_an_absent_old()
  local w = setup { ["a.txt"] = "one\n  two  three\nfour\n" }
  local r = w.call("edit", { path = "a.txt", old = "nothing like this", new = "x" })
  assert(is_failure(r) and r.code == "no_match")
  assert(#w.fs.wrote == 0)

  local w2 = setup { ["a.txt"] = "one\n  two  three\nfour\n" }
  local near = w2.call("edit", { path = "a.txt", old = "two three", new = "x" })
  assert(is_failure(near) and near.code == "no_match", "code is " .. tostring(near.code))
  assert(type(near.near) == "table", "no near miss was reported")
  assert(near.near.line == 2, "the near miss is at line " .. tostring(near.near.line))
  assert(w2.fs.files["a.txt"] == "one\n  two  three\nfour\n", "the file changed")
end

function T.edit_treats_magic_characters_literally()
  local w = setup { ["a.txt"] = "keep aXbYc\ntake a.b[c]%d\n" }
  local r = w.call("edit", { path = "a.txt", old = "a.b[c]%d", new = "ok" })
  assert(r.ok, r.reason)
  assert(r.replaced == 1 and r.line == 2)
  assert(w.fs.files["a.txt"] == "keep aXbYc\ntake ok\n", "a pattern expanded")
end

function T.edit_refuses_an_empty_old()
  local w = setup { ["a.txt"] = "x" }
  local r = w.call("edit", { path = "a.txt", old = "", new = "y" })
  assert(is_failure(r) and r.code == "bad_args", "code is " .. tostring(r.code))
  assert(r.field == "old")
  assert(string.find(r.reason, "write", 1, true), "the reason does not point at write")
  assert(#w.fs.wrote == 0)
end

function T.edit_refuses_when_old_equals_new()
  local w = setup { ["a.txt"] = "same" }
  local r = w.call("edit", { path = "a.txt", old = "same", new = "same" })
  assert(is_failure(r) and r.code == "unchanged")
  assert(#w.fs.wrote == 0)
end

function T.edit_names_crlf_when_that_is_the_difference()
  local w = setup { ["a.txt"] = "one\r\ntwo\r\n" }
  local r = w.call("edit", { path = "a.txt", old = "one\ntwo", new = "x" })
  assert(is_failure(r) and r.code == "no_match")
  assert(r.crlf == true, "the carriage returns were not named")
  assert(#w.fs.wrote == 0)
end

function T.edit_does_not_create_a_file()
  local w = setup { ["a.txt"] = "x" }
  local r = w.call("edit", { path = "new.txt", old = "a", new = "b" })
  assert(is_failure(r) and r.code == "not_found")
  assert(#w.fs.wrote == 0, "edit created a file")
  assert(w.fs.files["new.txt"] == nil)
end

function T.a_failed_write_leaves_the_file_alone()
  local w = setup({ ["a.txt"] = "before" }, {},
    { write_err = err("write", "unavailable", "disk full") })
  local r = w.call("edit", { path = "a.txt", old = "before", new = "after" })
  assert(is_failure(r) and r.code == "port_failed", "code is " .. tostring(r.code))
  assert(string.find(r.reason, "disk full", 1, true), "the port's words were dropped")
  local back = w.call("read", { path = "a.txt" })
  assert(back.ok and back.text == "before", "the file changed under a failed write")
end

function T.a_raising_port_becomes_a_result()
  local w = setup({ ["a.txt"] = "x" }, {}, { raise = { read = true } })
  local r = w.call("read", { path = "a.txt" })
  assert(is_failure(r) and r.code == "port_failed", "code is " .. tostring(r.code))
  assert(string.find(r.reason, "blew up", 1, true))
end

-- ------------------------------------------------------------------ writing

function T.write_creates_a_file_and_says_so()
  local w = setup { ["src/a.lua"] = "x" }
  local r = w.call("write", { path = "src/deep/b.lua", text = "hello" })
  assert(r.ok, r.reason)
  assert(r.created == true and r.bytes == 5 and r.bytes_before == nil)
  assert(#w.fs.wrote == 1 and w.fs.wrote[1].path == "src/deep/b.lua")
end

function T.write_reports_what_it_replaced()
  local w = setup { ["a.txt"] = "12345" }
  local r = w.call("write", { path = "a.txt", text = "x" })
  assert(r.ok, r.reason)
  assert(r.created == false, "an existing file read as created")
  assert(r.bytes_before == 5, "bytes_before is " .. tostring(r.bytes_before))
  assert(r.bytes == 1)
end

function T.write_of_empty_text_is_legal()
  local w = setup {}
  local r = w.call("write", { path = "a.txt", text = "" })
  assert(r.ok and r.bytes == 0 and r.created == true)
  assert(w.fs.files["a.txt"] == "")
end

function T.write_over_a_directory_is_refused()
  local w = setup { ["src/a.lua"] = "x" }
  local r = w.call("write", { path = "src", text = "x" })
  assert(is_failure(r) and r.code == "not_a_file" and r.kind == "dir")
  assert(#w.fs.wrote == 0)
end

function T.read_only_refuses_write_and_edit_but_not_read()
  local w = setup({ ["a.txt"] = "x" }, { read_only = true })
  local a = w.call("write", { path = "a.txt", text = "y" })
  local b = w.call("edit", { path = "a.txt", old = "x", new = "y" })
  assert(is_failure(a) and a.code == "read_only", "write gave " .. tostring(a.code))
  assert(is_failure(b) and b.code == "read_only", "edit gave " .. tostring(b.code))
  local r = w.call("read", { path = "a.txt" })
  assert(r.ok and r.text == "x")
  local schema = spec.schema(w.agent.declared)
  local about = {}
  for i = 1, #schema do about[schema[i].name] = schema[i].about end
  assert(string.find(about.write, "reading only", 1, true), "the about does not say so")
  assert(#w.fs.wrote == 0)
end

-- ------------------------------------------------------------- list, glob, search

function T.list_of_an_empty_directory_succeeds()
  local w = setup({ ["a.txt"] = "x" }, {}, { empty = { "hollow" } })
  local r = w.call("list", { path = "hollow" })
  assert(r.ok, r.reason)
  assert(#r.entries == 0 and r.count == 0)
end

function T.list_is_sorted_and_stable()
  local files = { ["b.txt"] = "1", ["a.txt"] = "22", ["c.txt"] = "333" }
  local w = setup(files)
  local one = w.call("list", {})
  local two = w.call("list", {})
  assert(one.ok and two.ok)
  assert(#one.entries == #two.entries)
  for i = 1, #one.entries do
    assert(one.entries[i].path == two.entries[i].path, "two runs disagree")
    assert(one.entries[i].kind == two.entries[i].kind)
  end
  assert(one.entries[1].path == "a.txt" and one.entries[3].path == "c.txt", "not sorted")
  assert(one.entries[1].size == 2, "a file size is missing")
end

function T.list_depth_defaults_to_one()
  local files = { ["a.txt"] = "x", ["deep/b.txt"] = "y", ["deep/down/c.txt"] = "z" }
  local w = setup(files, { max_depth = 2 })
  local shallow = w.call("list", {})
  local seen = {}
  for i = 1, #shallow.entries do seen[shallow.entries[i].path] = true end
  assert(seen["a.txt"] and seen["deep"], "the top is wrong")
  assert(not seen["deep/b.txt"], "depth one descended")

  local deeper = w.call("list", { depth = 2 })
  local seen2 = {}
  for i = 1, #deeper.entries do seen2[deeper.entries[i].path] = true end
  assert(seen2["deep/b.txt"], "depth two did not descend")

  local clamped = w.call("list", { depth = 40 })
  assert(clamped.ok, clamped.reason)
  assert(clamped.note == "depth clamped to 2", "note is " .. tostring(clamped.note))
end

function T.list_truncates_at_max_entries_deterministically()
  local files = {}
  for i = 1, 9 do files["f" .. i .. ".txt"] = "x" end
  local w = setup(files, { max_entries = 3 })
  local r = w.call("list", {})
  assert(r.ok, r.reason)
  assert(r.truncated == true and #r.entries == 3)
  assert(r.entries[1].path == "f1.txt" and r.entries[3].path == "f3.txt", "not the first three in order")
end

function T.a_walk_stops_at_max_scan()
  -- a tree far larger than the budget, built by the port rather than by a table
  local fs = {}
  fs.read = function () return nil, err("read", "not_found", "no") end
  fs.write = function () return true end
  fs.exists = function () return true end
  fs.list = function (dir)
    if dir ~= "" then return nil, err("list", "not_found", "no such directory") end
    local out = {}
    for i = 1, 50000 do out[i] = { name = string.format("f%05d.txt", i), kind = "file", size = 1 } end
    return out
  end
  local g = agent_double()
  local installed = tools_fs.install(g, { port = { fs = fs }, max_scan = 100, max_entries = 1000 })
  local tool = g.declared.tools[installed.tools.list]
  local r = tool.run { args = {}, fs = fs }
  assert(is_failure(r) and r.code == "budget", "code is " .. tostring(r.code))
  assert(r.scanned == 100, "scanned is " .. tostring(r.scanned))
  assert(#r.entries == 100, "the partial list is " .. #r.entries .. " long")
  assert(r.entries[1].path == "f00001.txt")
end

function T.a_cyclic_tree_terminates()
  -- every directory holds a directory called `a`, forever
  local fs = {}
  fs.read = function () return nil, err("read", "not_found", "no") end
  fs.write = function () return true end
  fs.exists = function () return true end
  fs.list = function ()
    return { { name = "a", kind = "dir" }, { name = "leaf.txt", kind = "file", size = 1 } }
  end
  local g = agent_double()
  local installed = tools_fs.install(g, { port = { fs = fs }, max_depth = 4, max_scan = 1000 })
  local tool = g.declared.tools[installed.tools.list]
  local r = tool.run { args = { depth = 99 }, fs = fs }
  assert(type(r) == "table", "the walk did not come back")
  assert(r.note == "depth clamped to 4", "note is " .. tostring(r.note))
  assert(r.count > 0)
  local deepest = 0
  for i = 1, #r.entries do
    local n = 0
    for _ in string.gmatch(r.entries[i].path, "/") do n = n + 1 end
    if n > deepest then deepest = n end
  end
  assert(deepest <= 3, "the walk went " .. deepest .. " separators deep past a clamp of 4")
end

function T.a_deadline_ends_a_walk()
  local files = { ["a/one.txt"] = "x", ["a/deep/two.txt"] = "y", ["b/three.txt"] = "z" }
  local clock = clock_double(1000)
  local calls = 0
  local fs = fs_double(files, { on_list = function ()
    calls = calls + 1
    if calls >= 2 then clock.t = clock.t + 0.060 end
  end })
  local g = agent_double()
  local installed = tools_fs.install(g, { port = { fs = fs, clock = clock }, deadline_ms = 50, max_depth = 5 })
  local tool = g.declared.tools[installed.tools.list]
  local r = tool.run { args = { depth = 5 }, fs = fs, clock = clock }
  assert(is_failure(r) and r.code == "deadline", "code is " .. tostring(r.code))
  assert(type(r.elapsed_ms) == "number" and r.elapsed_ms > 50, "elapsed_ms is " .. tostring(r.elapsed_ms))
  assert(type(r.entries) == "table", "no partial list came back")
end

function T.a_deadline_without_a_clock_is_refused_at_install()
  local g = agent_double()
  local ok = pcall(tools_fs.install, g, { port = { fs = fs_double {} }, deadline_ms = 50 })
  assert(not ok, "a deadline with no clock was accepted")
end

function T.glob_star_does_not_cross_a_separator()
  assert(tools_fs.glob_match("src/*.lua", "src/a.lua") == true)
  assert(tools_fs.glob_match("src/*.lua", "src/x/a.lua") == false)
  local w = setup { ["src/a.lua"] = "x", ["src/x/a.lua"] = "y" }
  local r = w.call("glob", { pattern = "src/*.lua" })
  assert(r.ok and #r.paths == 1 and r.paths[1] == "src/a.lua")
end

function T.glob_double_star_matches_zero_segments()
  assert(tools_fs.glob_match("src/**/*.lua", "src/a.lua") == true, "zero segments did not match")
  assert(tools_fs.glob_match("src/**/*.lua", "src/x/y/a.lua") == true)
  assert(tools_fs.glob_match("src/**/*.lua", "other/a.lua") == false)
  local w = setup { ["src/a.lua"] = "x", ["src/x/y/a.lua"] = "y", ["other/a.lua"] = "z" }
  local r = w.call("glob", { pattern = "src/**/*.lua" })
  assert(r.ok, r.reason)
  assert(#r.paths == 2, "matched " .. #r.paths)
  assert(r.paths[1] == "src/a.lua" and r.paths[2] == "src/x/y/a.lua")
end

function T.glob_character_classes_and_negation()
  assert(tools_fs.glob_match("[a-c]*.lua", "b1.lua") == true)
  assert(tools_fs.glob_match("[a-c]*.lua", "z1.lua") == false)
  assert(tools_fs.glob_match("[!a-c]*.lua", "z1.lua") == true)
  assert(tools_fs.glob_match("[^a-c]*.lua", "z1.lua") == true)
  assert(tools_fs.glob_match("[!a-c]*.lua", "b1.lua") == false)
  assert(tools_fs.glob_match("[]a]x", "]x") == true, "a leading ] is not literal")
  assert(tools_fs.glob_match("[]a]x", "ax") == true)
end

function T.glob_refuses_brace_alternation()
  local got, why = tools_fs.glob_match("src/{a,b}.lua", "src/a.lua")
  assert(got == nil and type(why) == "string")
  local w = setup { ["src/{a,b}.lua"] = "x" }
  local r = w.call("glob", { pattern = "src/{a,b}.lua" })
  assert(is_failure(r) and r.code == "unsupported_pattern", "code is " .. tostring(r.code))
  assert(r.pattern == "src/{a,b}.lua")
end

function T.glob_with_no_match_is_a_success()
  local w = setup { ["src/a.lua"] = "x" }
  local r = w.call("glob", { pattern = "**/*.rs" })
  assert(r.ok, "no match was a failure")
  assert(#r.paths == 0 and r.count == 0)
end

function T.search_finds_a_line_with_position()
  local w = setup { ["a.txt"] = "one\ntwo needle here\nthree\n" }
  local r = w.call("search", { pattern = "needle" })
  assert(r.ok, r.reason)
  assert(r.count == 1)
  local hit = r.hits[1]
  assert(hit.path == "a.txt" and hit.line == 2 and hit.col == 5, "at " .. hit.line .. ":" .. hit.col)
  assert(hit.text == "two needle here", "text is " .. string.format("%q", hit.text))
  assert(not string.find(hit.text, "\n", 1, true))
  assert(hit.trimmed == false)
end

function T.search_reports_only_the_first_hit_per_line()
  local w = setup { ["a.txt"] = "aa aa aa\nbb\n" }
  local r = w.call("search", { pattern = "aa", fixed = true })
  assert(r.ok and r.count == 1, "count is " .. tostring(r.count))
  assert(r.hits[1].col == 1)
end

function T.search_trims_a_long_line()
  local w = setup { ["a.txt"] = "needle" .. string.rep("x", 10000) .. "\n" }
  local r = w.call("search", { pattern = "needle" })
  assert(r.ok and r.count == 1)
  assert(#r.hits[1].text == 400, "the line is " .. #r.hits[1].text .. " bytes")
  assert(r.hits[1].trimmed == true)
end

function T.search_skips_binary_files()
  local w = setup { ["a.txt"] = "needle\n", ["b.bin"] = "nee\0dle needle\n" }
  local r = w.call("search", { pattern = "needle" })
  assert(r.ok, r.reason)
  assert(r.files_skipped == 1, "skipped " .. tostring(r.files_skipped))
  assert(r.count == 1 and r.hits[1].path == "a.txt")
  for i = 1, #r.hits do
    assert(r.hits[i].path ~= "b.bin", "a binary file came back")
  end
end

function T.search_refuses_a_malformed_lua_pattern()
  local w = setup { ["a.txt"] = "x\n" }
  local r = w.call("search", { pattern = "[a" })
  assert(is_failure(r) and r.code == "bad_pattern", "code is " .. tostring(r.code))
  assert(type(r.detail) == "string" and r.detail ~= "")
  local r2 = w.call("search", { pattern = "(" })
  assert(is_failure(r2) and r2.code == "bad_pattern", "an unfinished capture was not caught")
  -- this one only bites on a line that reaches the trailing %
  local r3 = w.call("search", { pattern = "x%" })
  assert(is_failure(r3) and r3.code == "bad_pattern", "code is " .. tostring(r3.code))
  -- and %( is a literal bracket, not malformed at all
  local r4 = w.call("search", { pattern = "%(" })
  assert(r4.ok, "%( was refused as malformed")
end

function T.search_does_not_understand_pcre()
  local w = setup { ["a.txt"] = "12345\n", ["b.txt"] = "a\\d+b\n" }
  local r = w.call("search", { pattern = "\\d+" })
  assert(r.ok, r.reason)
  assert(r.count == 1, "count is " .. tostring(r.count))
  assert(r.hits[1].path == "b.txt", "a PCRE class matched digits")
end

function T.search_honours_its_glob_filter()
  local w = setup { ["src/a.lua"] = "needle\n", ["doc/b.md"] = "needle\n" }
  local r = w.call("search", { pattern = "needle", glob = "src/**" })
  assert(r.ok, r.reason)
  assert(r.files_scanned == 1, "scanned " .. tostring(r.files_scanned))
  assert(r.count == 1 and r.hits[1].path == "src/a.lua")
end

function T.search_stops_at_its_hit_cap()
  local files = {}
  for i = 1, 20 do files["f" .. i .. ".txt"] = "needle\n" end
  local w = setup(files, { max_hits = 5 })
  local r = w.call("search", { pattern = "needle" })
  assert(r.ok, r.reason)
  assert(r.count == 5 and r.truncated == true)
  local r2 = w.call("search", { pattern = "needle", max = 2 })
  assert(r2.ok and r2.count == 2 and r2.truncated == true)
end

-- ------------------------------------------------------------------ boundaries

function T.tools_fs_names_no_vendor()
  local fh = io.open(root .. "/src/tools_fs.lua", "rb")
  assert(fh, "cannot open the source")
  local src = fh:read("*a")
  fh:close()
  local banned = {
    "%f[%w]io%.", "%f[%w]os%.", "%f[%w]require%f[%W]", "%f[%w]loadstring%f[%W]",
    "%f[%w]load%s*%(", "%f[%w]dofile%f[%W]", "popen", "%f[%w]print%s*%(",
  }
  for i = 1, #banned do
    local at = string.find(src, banned[i])
    assert(not at, "the source names " .. banned[i] .. " at byte " .. tostring(at))
  end
end

function T.no_state_survives_a_call()
  local w = setup { ["a.txt"] = "hello\n" }
  local one = w.call("read", { path = "a.txt" })
  local two = w.call("read", { path = "a.txt" })
  for k, v in pairs(one) do
    assert(two[k] == v, "the field " .. k .. " changed between two identical calls")
  end

  -- two agents in one process keep their own configs
  local a = setup({ ["a.txt"] = "x" }, { max_bytes = 4 })
  local b = setup({ ["a.txt"] = string.rep("y", 50) }, { max_bytes = 1000 })
  local ra = a.call("read", { path = "a.txt" })
  local rb = b.call("read", { path = "a.txt" })
  assert(ra.ok and rb.ok, "the two installs interfered")
  local big = a.call("write", { path = "a.txt", text = string.rep("z", 50) })
  assert(big.ok)
  local reread = a.call("read", { path = "a.txt" })
  assert(is_failure(reread) and reread.code == "too_large", "the first agent's limit moved")
end

function T.opts_are_copied_not_held()
  local fs = fs_double { ["a.txt"] = "hello" }
  local g = agent_double()
  local opts = { port = { fs = fs }, max_bytes = 1000, deny = {} }
  local installed = tools_fs.install(g, opts)
  opts.max_bytes = 1
  opts.deny[1] = "**"
  opts.read_only = true
  local tool = g.declared.tools[installed.tools.read]
  local r = tool.run { args = { path = "a.txt" }, fs = fs }
  assert(r.ok, "editing opts afterwards changed what the tools do: " .. tostring(r.code))
end

function T.every_failure_is_a_table_not_an_error()
  local w = setup({ ["a.txt"] = "hello\nworld\n", ["src/b.lua"] = "x" },
    { deny = { "secret/**" }, max_bytes = 64, max_entries = 5, max_scan = 50 })
  local junk = { nil, 7, {}, true, "", string.rep("q", 5000), "a\0b", "../x", "/etc/passwd",
                 "~", ".", "..", "a//b", "a/./b", -1, 0, 1.5, "%(", "{a,b}" }
  local names = { "read", "write", "edit", "list", "glob", "search" }
  local fields = { "path", "text", "old", "new", "expect", "offset", "limit",
                   "depth", "pattern", "glob", "fixed", "max" }
  local checked = 0
  for n = 1, #names do
    for f = 1, #fields do
      for j = 1, #junk do
        local args = { path = "a.txt", text = "t", old = "hello", new = "z", pattern = "hello" }
        args[fields[f]] = junk[j]
        local ran, r = pcall(w.call, names[n], args)
        assert(ran, names[n] .. " raised on " .. fields[f] .. " = " .. tostring(junk[j]) .. ": " .. tostring(r))
        assert(type(r) == "table", names[n] .. " did not answer with a table")
        assert(type(r.ok) == "boolean", names[n] .. " has no ok")
        if r.ok == false then
          assert(type(r.code) == "string" and r.code ~= "", names[n] .. " failed with no code")
          assert(type(r.reason) == "string" and r.reason ~= "", names[n] .. " failed with no reason")
          assert(not string.find(r.reason, "\n", 1, true), names[n] .. "'s reason holds a newline")
        end
        checked = checked + 1
      end
    end
  end
  assert(checked > 500, "only " .. checked .. " shapes were tried")
end

-- ------------------------------------------------- a world that answers nothing

-- Every tool, called with no filesystem at all and again with one that owes every
-- call. `install` allows both — spec section 4 says `port` is optional and a body
-- takes the harness's `ctx.fs` — so a body has to state the lack, not fall over it.
local NO_PORT_CALLS = {
  { "read",   { path = "a.txt" } },
  { "write",  { path = "a.txt", text = "x" } },
  { "edit",   { path = "a.txt", old = "a", new = "b" } },
  { "list",   {} },
  { "list",   { path = "d" } },
  { "glob",   { pattern = "*" } },
  { "glob",   { pattern = "*", path = "d" } },
  { "search", { pattern = "x" } },
  { "search", { pattern = "x", path = "d" } },
}

local function sweep_without_a_port(ctx_fs)
  local g = agent_double()
  local installed = tools_fs.install(g, {})
  for i = 1, #NO_PORT_CALLS do
    local name, args = NO_PORT_CALLS[i][1], NO_PORT_CALLS[i][2]
    local where = name .. " " .. (args.path or "the workspace root")
    local tool = g.declared.tools[installed.tools[name]]
    local ran, r = pcall(tool.run, { args = args, fs = ctx_fs })
    assert(ran, where .. " raised out of the tool body: " .. tostring(r))
    assert(type(r) == "table", where .. " did not answer with a table")
    assert(is_failure(r), where .. " answered ok = " .. tostring(r.ok) ..
      " with no filesystem to answer from")
    assert(r.code == "port_failed", where .. " gave " .. tostring(r.code))
  end
end

function T.a_run_with_no_filesystem_is_a_result_not_a_raise()
  sweep_without_a_port(nil)
end

function T.a_port_that_cannot_list_is_not_an_empty_workspace()
  -- a table where the calls should be. Answering `ok = true, count = 0` here would
  -- tell the model the workspace is empty, which is a wrong answer and not a refused
  -- one -- the worst shape a failure can take.
  sweep_without_a_port {}
end

function T.a_deadline_with_no_clock_at_call_time_is_refused()
  -- `install` can only refuse this when it was handed a port; with none, the lack has
  -- to be caught at the call rather than the budget quietly not being kept.
  local g = agent_double()
  local installed = tools_fs.install(g, { deadline_ms = 50 })
  local fs = fs_double { ["a.txt"] = "x" }
  local r = g.declared.tools[installed.tools.list].run { args = {}, fs = fs }
  assert(is_failure(r) and r.code == "port_failed", "code is " .. tostring(r.code))
  assert(string.find(r.reason, "clock", 1, true), "the reason does not name the clock")
  local ok = g.declared.tools[installed.tools.list].run { args = {}, fs = fs, clock = clock_double(0) }
  assert(ok.ok, "a clock on the context was not used: " .. tostring(ok.code))
end

function T.the_context_port_beats_the_one_named_at_install()
  -- spec section 3: a host that wires one port and runs another gets the running one.
  local wired  = fs_double { ["a.txt"] = "WIRED" }
  local running = fs_double { ["a.txt"] = "RUNNING" }
  local g = agent_double()
  local installed = tools_fs.install(g, { port = { fs = wired } })
  local r = g.declared.tools[installed.tools.read].run { args = { path = "a.txt" }, fs = running }
  assert(r.ok, r.reason)
  assert(r.text == "RUNNING", "the stale port answered: " .. tostring(r.text))
  assert(#wired.read_calls == 0, "the port named at install was read anyway")
end

function T.list_glob_and_search_on_a_file_say_not_a_dir()
  local w = setup { ["src/a.lua"] = "x\n" }
  local calls = {
    { "list",   { path = "src/a.lua" } },
    { "glob",   { pattern = "*", path = "src/a.lua" } },
    { "search", { pattern = "x", path = "src/a.lua" } },
  }
  for i = 1, #calls do
    local r = w.call(calls[i][1], calls[i][2])
    assert(is_failure(r) and r.code == "not_a_dir", calls[i][1] .. " gave " .. tostring(r.code))
    assert(r.kind == "file", calls[i][1] .. " did not say what it found")
  end
  local gone = w.call("list", { path = "nowhere" })
  assert(is_failure(gone) and gone.code == "not_found", "a missing directory gave " .. tostring(gone.code))
end

function T.read_over_max_bytes_still_allows_a_slice()
  -- the refusal has to fall on the slice, or the advice it gives is advice that
  -- cannot work.
  local w = setup({ ["big.txt"] = string.rep("y\n", 100) }, { max_bytes = 20 })
  local whole = w.call("read", { path = "big.txt" })
  assert(is_failure(whole) and whole.code == "too_large")
  local everything = w.call("read", { path = "big.txt", offset = 1 })
  assert(is_failure(everything) and everything.code == "too_large", "an unbounded slice was allowed")
  assert(everything.size == 200 and everything.limit == 20)
  local part = w.call("read", { path = "big.txt", offset = 1, limit = 3 })
  assert(part.ok, "a slice inside the limit was refused: " .. tostring(part.code))
  assert(part.text == "y\ny\ny\n" and part.bytes == 6 and part.eof == false)
end

function T.edit_judges_the_path_before_it_judges_the_text()
  -- `unchanged` is an opinion about a file. A path that leaves the workspace, or one a
  -- deny rule keeps out of reach, is not a file this tool may hold an opinion about.
  local w = setup({ ["a.txt"] = "x" }, { deny = { "secret/**" } })
  local denied = w.call("edit", { path = "secret/k", old = "a", new = "a" })
  assert(is_failure(denied) and denied.code == "denied", "gave " .. tostring(denied.code))
  local outside = w.call("edit", { path = "../x", old = "a", new = "a" })
  assert(is_failure(outside) and outside.code == "outside_workspace", "gave " .. tostring(outside.code))
  local empty = w.call("edit", { path = "secret/k", old = "", new = "" })
  assert(is_failure(empty) and empty.code == "denied", "gave " .. tostring(empty.code))
  -- and inside the workspace the text is still judged
  local same = w.call("edit", { path = "a.txt", old = "x", new = "x" })
  assert(is_failure(same) and same.code == "unchanged")
  assert(#w.fs.wrote == 0)
end

function T.a_glob_of_many_stars_answers_in_time()
  -- A pattern is something a model asks for, and a deny rule is matched against every
  -- path a walk visits, so the matcher's cost is the harness's cost. A recursive `*`
  -- branches at every star: `a*a*a*a*a*a*a*a*b` against a forty-byte name took twelve
  -- seconds, inside the matcher where neither max_scan nor deadline_ms can see it. A
  -- count hook turns a return of that shape into a failure rather than a wedged run.
  local pattern = "a*a*a*a*a*a*a*a*b"
  local name = string.rep("a", 200)
  local blew = false
  debug.sethook(function ()
    blew = true
    error("the glob matcher ran past its instruction budget", 2)
  end, "", 4000000)
  local ran, got = pcall(tools_fs.glob_match, pattern, name)
  local ran2, got2 = pcall(tools_fs.glob_match, pattern, name .. "b")
  debug.sethook()
  assert(not blew and ran and ran2, "the matcher did not finish: " .. tostring(got or got2))
  assert(got == false, "a name with no b matched")
  assert(got2 == true, "a name ending in b did not match")
end

-- The fakes above inject failures no shared double needs to. This one proves the
-- contract the tools were written to is the one src/double.lua actually keeps.
function T.the_shared_double_is_enough_of_a_world()
  local got, double = pcall(require, "double")
  if not got then return end          -- another subsystem's file, and not here yet
  local p = double.world { fs = {
    ["src/a.lua"] = "local x = 1\nreturn x\n",
    ["doc/b.md"]  = "needle here\n",
  } }
  local g = agent_double()
  local installed = tools_fs.install(g, { port = p })
  local function call(name, args)
    return g.declared.tools[installed.tools[name]].run { args = args, fs = p.fs, clock = p.clock }
  end

  local r = call("read", { path = "src/a.lua" })
  assert(r.ok and r.text == "local x = 1\nreturn x\n", "read gave " .. tostring(r.code))
  assert(call("read", { path = "nope.lua" }).code == "not_found")
  assert(call("read", { path = "src" }).code == "not_a_file")

  local l = call("list", { path = "", depth = 3 })
  assert(l.ok and l.count == 4, "list gave " .. tostring(l.count))
  assert(l.entries[1].path == "doc" and l.entries[1].kind == "dir")

  local gl = call("glob", { pattern = "**/*.lua" })
  assert(gl.ok and #gl.paths == 1 and gl.paths[1] == "src/a.lua")

  local se = call("search", { pattern = "needle" })
  assert(se.ok and se.count == 1 and se.hits[1].path == "doc/b.md" and se.hits[1].line == 1)

  local e = call("edit", { path = "src/a.lua", old = "x = 1", new = "x = 2" })
  assert(e.ok and e.replaced == 1, "edit gave " .. tostring(e.code))
  local back = call("read", { path = "src/a.lua" })
  assert(back.text == "local x = 2\nreturn x\n", "the edit did not land")

  local wr = call("write", { path = "new/c.txt", text = "hi" })
  assert(wr.ok and wr.created == true)
  assert(call("read", { path = "new/c.txt" }).text == "hi")

  assert(call("read", { path = "../etc/passwd" }).code == "outside_workspace")
end

function T.find_all_and_line_of_hold_their_edges()
  local at = tools_fs.find_all("aaaa", "aa")
  assert(#at == 2 and at[1] == 1 and at[2] == 3, "overlapping matches were counted")
  assert(#tools_fs.find_all("abc", "") == 0, "an empty needle found something")
  assert(#tools_fs.find_all("", "a") == 0)
  assert(#tools_fs.find_all("a.b", ".") == 1, "the needle was read as a pattern")

  local line, col = tools_fs.line_of("one\ntwo\nthree", 5)
  assert(line == 2 and col == 1, "at " .. line .. ":" .. col)
  local l2, c2 = tools_fs.line_of("one\ntwo", 1)
  assert(l2 == 1 and c2 == 1)
  local l3, c3 = tools_fs.line_of("one\ntwo", 7)
  assert(l3 == 2 and c3 == 3, "at " .. l3 .. ":" .. c3)
end

return T
