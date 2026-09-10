-- config: configuration, profiles and secrets.
--
-- Happy paths first, then the awkward ones -- and the awkward ones here are mostly
-- about a credential, because a module that holds one and cannot prove where it went
-- is worth less than no module at all. Every test asserts with plain `assert` and
-- prints nothing when it holds.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local config = require "config"

local T = {}

-- ---------------------------------------------------------------------------
-- Doubles. `config` reads two port fields, so these are the whole world it can see.
-- They are written here rather than taken from src/double.lua because src/double.lua
-- has no environment port yet: spec/config.md section 2 asks for `double.env`, and
-- until spec/port.md adopts an environment port this test wires its own.

local function env_double(vars, how)
  how = how or {}
  local e = { asked = {} }
  function e.get(name)
    e.asked[#e.asked + 1] = name
    if how.raises then error("the environment is on fire") end
    return vars[name]
  end
  if not how.no_names then
    function e.names()
      if how.names_raise then error("no listing today") end
      local out = {}
      for k in pairs(vars) do out[#out + 1] = k end
      table.sort(out)
      return out
    end
  end
  return e
end

-- A filesystem port with exactly the one call `config` makes. `files` maps a path to
-- text; `errors` maps a path to a port error code.
local function fs_double(files, errors, how)
  local f = { read_paths = {}, wrote = {} }
  function f.read(path)
    f.read_paths[#f.read_paths + 1] = path
    if how and how.raises then error("the disk is on fire") end
    local code = errors and errors[path]
    if code then
      return nil, { port = "fs", call = "read", code = code, message = code .. ": " .. path }
    end
    local text = files and files[path]
    if text == nil then
      return nil, { port = "fs", call = "read", code = "not_found", message = "no such file: " .. path }
    end
    return text
  end
  function f.write(path, text) f.wrote[#f.wrote + 1] = path; return true end
  return f
end

-- ---------------------------------------------------------------------------
-- Test helpers.

local function raised(fn, ...)
  local ok, message = pcall(fn, ...)
  return (not ok), tostring(message)
end

local function problem_with(problems, code)
  assert(type(problems) == "table", "there are problems to look through")
  for i = 1, #problems do
    if problems[i].code == code then return problems[i] end
  end
  local seen = {}
  for i = 1, #problems do seen[i] = tostring(problems[i].code) .. "/" .. tostring(problems[i].message) end
  error("no problem with code " .. code .. "; there were: " .. table.concat(seen, " | "), 2)
end

local function warning_about(c, needle)
  for i = 1, #c.warnings do
    if c.warnings[i]:find(needle, 1, true) then return c.warnings[i] end
  end
  return nil
end

-- Every string reachable from a value, at any depth, keys as well as values. This is
-- how the secrecy tests search: not for a field they expect, for anything at all.
local function every_string(v, out, seen)
  out = out or {}
  seen = seen or {}
  local t = type(v)
  if t == "string" then out[#out + 1] = v
  elseif t == "number" or t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" and not seen[v] then
    seen[v] = true
    for k, item in pairs(v) do
      every_string(k, out, seen)
      every_string(item, out, seen)
    end
  end
  return out
end

local function holds(v, needle)
  local all = every_string(v)
  for i = 1, #all do
    if all[i]:find(needle, 1, true) then return true end
  end
  return false
end

-- A stable rendering, so a table can be compared with itself from before a call.
local function render(v, seen)
  seen = seen or {}
  local t = type(v)
  if t ~= "table" then return string.format("%s(%s)", t, tostring(v)) end
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for i = 1, #keys do
    parts[i] = tostring(keys[i]) .. "=" .. render(v[keys[i]], seen)
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

local KINDS = {
  { name = "s", kind = "string", about = "a string", env = "PI_S" },
  { name = "n", kind = "number", about = "a number", env = "PI_N" },
  { name = "b", kind = "boolean", about = "a boolean", env = "PI_B" },
  { name = "l", kind = "list", about = "a list", env = "PI_L" },
}

-- ---------------------------------------------------------------------------
-- The happy paths.

function T.defaults_alone_are_a_valid_config()
  local c = assert(config.load())
  assert(config.get(c, "budget") == 24)
  assert(config.get(c, "approve") == "ask")
  assert(config.get(c, "model") == nil, "no default, and nil is a legitimate answer")
  assert(c.profile == nil)
  assert(#c.layers == 1 and c.layers[1].name == "builtin")
  assert(c.layers[1].n == 6, "six built-in settings carry a default")
  assert(config.explain(c, "budget").layer == "builtin")
  assert(#c.warnings == 0)
end

function T.a_file_beats_a_default()
  local c = assert(config.load { text = "-- the project's own\nbudget = 12\n" })
  assert(config.get(c, "budget") == 12)
  local why = config.explain(c, "budget")
  assert(why.layer == "file:(text)", why.layer)
  assert(why.where == "line 2", why.where)
  assert(why.raw == "12", tostring(why.raw))
  assert(why.shadowed[1].layer == "builtin")
end

function T.the_environment_beats_a_file()
  local c = assert(config.load {
    text = "budget = 12\n",
    port = { env = env_double { PI_BUDGET = "7" } },
  })
  assert(config.get(c, "budget") == 7)
  local why = config.explain(c, "budget")
  assert(why.layer == "env" and why.where == "PI_BUDGET", why.layer .. " " .. tostring(why.where))
  assert(why.raw == "7")
  assert(why.shadowed[1].layer == "file:(text)" and why.shadowed[1].raw == "12")
  assert(why.shadowed[2].layer == "builtin")
end

function T.an_override_beats_the_environment()
  local c = assert(config.load {
    text = "budget = 12\n",
    port = { env = env_double { PI_BUDGET = "7" } },
    override = { budget = 3 },
  })
  assert(config.get(c, "budget") == 3)
  local why = config.explain(c, "budget")
  assert(why.layer == "override" and why.raw == nil)
  assert(#why.shadowed == 3, #why.shadowed)
  assert(why.shadowed[1].layer == "env")
  assert(why.shadowed[2].layer == "file:(text)")
  assert(why.shadowed[3].layer == "builtin")
end

function T.a_later_file_beats_an_earlier_one()
  local c = assert(config.load {
    files = {
      { where = "user.conf", text = "budget = 4\n" },
      { where = "project.conf", text = "budget = 9\n" },
    },
  })
  assert(config.get(c, "budget") == 9)
  local names = {}
  for i = 1, #c.layers do names[i] = c.layers[i].name end
  assert(table.concat(names, " ") == "builtin file:user.conf file:project.conf", table.concat(names, " "))
  assert(c.layers[2].n == 0, "the earlier file won nothing and says so")
  assert(c.layers[3].n == 1)
  -- two entries may carry the same `where`, and each layer reports what it alone won
  local same = assert(config.load {
    files = { { where = "x.conf", text = "budget = 1\n" },
              { where = "x.conf", text = "timeout = 5\n" } },
  })
  assert(same.layers[2].n == 1 and same.layers[3].n == 1,
    "counted by position, not by name: " .. same.layers[2].n .. "," .. same.layers[3].n)
  assert(same.layers[1].n == 4, same.layers[1].n)
end

function T.a_profile_beats_its_own_files_base()
  local c = assert(config.load {
    files = {
      { where = "project.conf", text = "budget = 1\ntimeout = 5\n\n[profile.review]\nbudget = 2\n" },
      { where = "user.conf", text = "attempts = 7\n" },
    },
    profile = "review",
  })
  assert(config.get(c, "budget") == 2)
  assert(config.get(c, "timeout") == 5, "the base of the same file still stands where the profile is silent")
  assert(config.get(c, "attempts") == 7, "the other file is untouched by the profile")
  assert(config.explain(c, "budget").layer == "profile:review@project.conf")
  assert(c.profile == "review")
end

function T.the_profile_is_chosen_from_the_environment()
  local c = assert(config.load {
    text = "budget = 1\n[profile.review]\nbudget = 2\n",
    port = { env = env_double { PI_PROFILE = "review" } },
  })
  assert(c.profile == "review")
  assert(config.get(c, "budget") == 2)
  local why = config.explain(c, "profile")
  assert(why.layer == "env" and why.where == "PI_PROFILE", tostring(why.layer))
  assert(why.value == "review")
end

function T.every_kind_reads_back_from_text()
  local schema = config.schema(KINDS)
  local from_file = assert(config.load {
    schema = schema,
    text = 's = plain words\nn = 12.5\nb = true\nl = a, b ,c\n',
  })
  assert(config.get(from_file, "s") == "plain words")
  assert(config.get(from_file, "n") == 12.5)
  assert(config.get(from_file, "b") == true)
  local list = config.get(from_file, "l")
  assert(#list == 3 and list[1] == "a" and list[2] == "b" and list[3] == "c", render(list))

  local from_env = assert(config.load {
    schema = schema,
    port = { env = env_double { PI_S = "x", PI_N = "3", PI_B = "FALSE", PI_L = " one , two " } },
  })
  assert(config.get(from_env, "s") == "x")
  assert(config.get(from_env, "n") == 3)
  assert(config.get(from_env, "b") == false)
  local whyb = config.explain(from_env, "b")
  assert(whyb.set == true and whyb.value == false and whyb.raw == "FALSE",
    "a boolean that resolved to false is set, and explain says which layer set it")
  local two = config.get(from_env, "l")
  assert(#two == 2 and two[1] == "one" and two[2] == "two", render(two))

  for text, want in pairs({ ["b = 1"] = true, ["b = 0"] = false, ["b = TRUE"] = true }) do
    local c = assert(config.load { schema = schema, text = text })
    assert(config.get(c, "b") == want, text)
  end

  local bad, problems = config.load { schema = schema, text = "n = soon\n" }
  assert(bad == nil)
  local p = problem_with(problems, "wrong_type")
  assert(p.setting == "n" and p.where == "line 1", render(p))
  assert(p.message:find("soon", 1, true), p.message)
end

function T.a_quoted_value_keeps_its_spaces_and_is_never_split()
  local c = assert(config.load {
    schema = config.schema(KINDS),
    text = 'l = "a, b"\ns = "  leading space kept, \\"quoted\\", and a tab\\there"\n',
  })
  local list = config.get(c, "l")
  assert(#list == 1 and list[1] == "a, b", render(list))
  local s = config.get(c, "s")
  assert(s:sub(1, 2) == "  ", "leading whitespace survives a quoted value")
  assert(s:find('"quoted"', 1, true), s)
  assert(s:find("\t", 1, true), "the four escapes are read")
  assert(not s:find("\\", 1, true), s)
end

function T.parse_returns_declaration_order_and_line_numbers()
  local tree = assert(config.parse(
    "-- a comment runs to the end of the line\n" ..
    "model   = openrouter:inception/mercury-2.5\n" ..
    "budget  = 12\n" ..
    "\n" ..
    "[profile.review]\n" ..
    "budget  = 4\n" ..
    "timeout = 120\n"))
  assert(#tree.base == 2)
  assert(tree.base[1].key == "model" and tree.base[1].line == 2)
  assert(tree.base[1].raw == "openrouter:inception/mercury-2.5", tree.base[1].raw)
  assert(tree.base[2].key == "budget" and tree.base[2].raw == "12" and tree.base[2].line == 3)
  local review = tree.profiles.review
  assert(#review == 2)
  assert(review[1].key == "budget" and review[1].line == 6)
  assert(review[2].key == "timeout" and review[2].raw == "120" and review[2].line == 7)
  -- parse knows nothing about settings, so an unknown key is not its problem
  local other = assert(config.parse("nonesuch = 1\n"))
  assert(other.base[1].key == "nonesuch")
  -- and an empty file is a state, not an error
  local empty = assert(config.parse(""))
  assert(#empty.base == 0 and next(empty.profiles) == nil)
  -- and a section header that is not [profile.<name>] is named rather than guessed at
  local bad, why = config.parse("[settings]\nbudget = 1\n")
  assert(bad == nil and why[1].code == "unknown_section" and why[1].where == "line 1", render(why))
end

function T.report_has_a_line_per_setting_sorted_by_name()
  local c = assert(config.load {
    text = "model = openrouter:inception/mercury-2.5\n",
    port = { env = env_double { PI_API_KEY = "sk-live-abcdef", PI_LOG_LEVEL = "debug" } },
  })
  local lines = config.report(c)
  assert(#lines == 10, #lines)
  local names = {}
  for i = 1, #lines do names[i] = lines[i]:match("^(%S+)") end
  local sorted = {}
  for i = 1, #names do sorted[i] = names[i] end
  table.sort(sorted)
  assert(table.concat(names, ",") == table.concat(sorted, ","), table.concat(names, ","))
  local found = false
  for i = 1, #lines do
    if names[i] == "key" then
      found = true
      assert(lines[i]:find("(secret, set)", 1, true), lines[i])
      assert(lines[i]:find("env PI_API_KEY", 1, true), lines[i])
    end
  end
  assert(found)
  -- and it cannot raise, on any config it is handed
  assert(#config.report(assert(config.load())) == 10)
  assert(#config.report(assert(config.load { schema = config.schema {} })) == 0)
  -- including a whole number no integer format holds: %d refuses it under 5.4 and
  -- prints a clamped integer that is not the value under LuaJIT, and report may do
  -- neither, because it cannot raise and it may not lie
  local huge = assert(config.load { text = "budget = 1e20\n" })
  local shown
  for _, line in ipairs(config.report(huge)) do
    if line:match("^budget%s") then shown = line end
  end
  assert(shown and shown:find("1e+20", 1, true), tostring(shown))
end

function T.profiles_lists_what_the_files_declared()
  local c = assert(config.load {
    files = {
      { where = "a.conf", text = "[profile.review]\nbudget = 1\n[profile.ci]\nbudget = 2\n" },
      { where = "b.conf", text = "[profile.ci]\ntimeout = 9\n" },
    },
  })
  local names = config.profiles(c)
  assert(#names == 2 and names[1] == "ci" and names[2] == "review", table.concat(names, ","))
  names[1] = "tampered"
  assert(config.profiles(c)[1] == "ci", "a fresh list every call")
  assert(#config.profiles(assert(config.load())) == 0)
end

function T.with_derives_without_touching_its_parent()
  local c = assert(config.load())
  local c2 = config.with(c, { budget = 2 })
  assert(config.get(c, "budget") == 24, "the parent is unchanged")
  assert(config.get(c2, "budget") == 2)
  assert(c2.layers[#c2.layers].name == "override:2", c2.layers[#c2.layers].name)
  assert(#c.layers == 1, "and gained no layer of its own")
  local why = config.explain(c2, "budget")
  assert(why.layer == "override:2" and why.shadowed[1].layer == "builtin")
  local c3 = config.with(c2, { budget = 1 })
  assert(c3.layers[#c3.layers].name == "override:3")
  assert(config.get(c2, "budget") == 2)
  assert(config.explain(c3, "budget").shadowed[1].layer == "override:2")
end

-- ---------------------------------------------------------------------------
-- Adversarial from here down. These are the ones worth writing first.

function T.a_secret_is_never_in_the_config_table()
  local key = "sk-live-abcdef.0123"
  local c = assert(config.load { port = { env = env_double { PI_API_KEY = key } } })
  assert(config.secret(c, "key") == key, "the one door it leaves by")
  assert(not holds(c, key), "walked to any depth, the config table does not hold it")
  assert(not tostring(c):find(key, 1, true), tostring(c))
  assert(tostring(c):find("config(", 1, true), tostring(c))
  assert(not holds(config.public(c), key))
  assert(config.public(c).key == nil, "absent, not present and nil")
  assert(not holds(config.report(c), key))
  assert(not holds(config.explain(c, "key"), key))
  -- and those four fields are all there is
  local allowed = { profile = true, layers = true, warnings = true, schema = true }
  local fields = {}
  for k in pairs(c) do
    assert(allowed[k], "a config carries " .. tostring(k) .. ", and it carries only four fields")
    fields[#fields + 1] = k
  end
  table.sort(fields)
  assert(table.concat(fields, ",") == "layers,schema,warnings", table.concat(fields, ","))
  local named = assert(config.load {
    text = "[profile.review]\nbudget = 2\n", profile = "review",
    port = { env = env_double { PI_API_KEY = key } },
  })
  assert(named.profile == "review" and not holds(named, key))
end

function T.the_ordinary_getter_refuses_a_secret()
  local key = "sk-live-abcdef"
  local c = assert(config.load { port = { env = env_double { PI_API_KEY = key } } })
  local bad, message = raised(config.get, c, "key")
  assert(bad, "config.get refuses a secret rather than redacting one")
  assert(message:find("key", 1, true), message)
  assert(message:find("config.secret", 1, true), message)
  assert(not message:find(key, 1, true), message)
end

function T.a_secret_in_a_file_is_refused_and_not_echoed()
  local key = "sk-live-abcdef"
  local c, problems = config.load { text = "budget = 4\nkey = " .. key .. "\n" }
  assert(c == nil, "the load fails rather than half-applying the file")
  local p = problem_with(problems, "not_allowed")
  assert(p.setting == "key" and p.where == "line 2", render(p))
  assert(not holds(p, key), "the value is in no field of the problem: " .. render(p))
  assert(p.message:find("PI_API_KEY", 1, true), p.message)
  -- config.parse alone still returns it: it has no schema and cannot know
  local tree = assert(config.parse("key = " .. key .. "\n"))
  assert(tree.base[1].raw == key)
  -- and with the line gone, nothing supplied a key
  local ok = assert(config.load { text = "budget = 4\n" })
  assert(config.secret(ok, "key") == nil)
  -- an ordinary setting with file = false is refused the same way, and a required
  -- setting nothing supplied is `missing`, naming what would have supplied it
  local schema = config.schema {
    { name = "budget", kind = "number", about = "steps", default = 4, file = false },
    { name = "key", kind = "string", about = "a credential", secret = true,
      required = true, env = { "PI_API_KEY", "OPENROUTER_API_KEY" } },
  }
  local none, refused = config.load { schema = schema, text = "budget = 2\n" }
  assert(none == nil)
  assert(problem_with(refused, "not_allowed").setting == "budget")
  local m = problem_with(refused, "missing")
  assert(m.setting == "key", render(m))
  assert(m.message:find("PI_API_KEY", 1, true)
    and m.message:find("OPENROUTER_API_KEY", 1, true), m.message)
  assert(not holds(m, key))
end

function T.an_override_that_supplies_a_secret_raises_without_echoing_it()
  local key = "sk-live-abcdef"
  local bad, message = raised(config.load, { override = { key = key } })
  assert(bad and message:find("key", 1, true) and message:find("secret", 1, true), message)
  assert(not message:find(key, 1, true), message)
  local c = assert(config.load())
  local bad2, message2 = raised(config.with, c, { key = key })
  assert(bad2 and message2:find("secret", 1, true), message2)
  assert(not message2:find(key, 1, true), message2)
end

function T.redact_removes_a_secret_from_a_string_a_table_and_a_key()
  local key = "sk-live-100%-a.b-c"
  local c = assert(config.load { port = { env = env_double { PI_API_KEY = key } } })
  assert(config.redact(c, "bearer " .. key .. " twice " .. key)
    == "bearer [redacted] twice [redacted]")
  local t = { header = "Bearer " .. key, [key] = "as a key", nested = { { key } } }
  local clean = config.redact(c, t)
  assert(not holds(clean, key), render(clean))
  assert(clean.header == "Bearer [redacted]")
  assert(clean["[redacted]"] == "as a key", "a credential used as a key is scrubbed too")
  assert(clean.nested[1][1] == "[redacted]")
  assert(t.header == "Bearer " .. key, "the original is not touched")
  assert(config.redact(c, 12) == 12 and config.redact(c, true) == true)
  -- the match is plain text, never a Lua pattern
  assert(config.redact(c, "sk-live-100Xa%bXc") == "sk-live-100Xa%bXc")
  -- an empty secret would match everywhere, so it is skipped
  local none = assert(config.load { port = { env = env_double { PI_API_KEY = "" } } })
  assert(config.redact(none, "anything at all") == "anything at all")
end

function T.redact_terminates_on_a_cycle_and_a_deep_table()
  local c = assert(config.load { port = { env = env_double { PI_API_KEY = "sk-live-abcdef" } } })
  local loop = { name = "sk-live-abcdef" }
  loop.self = loop
  local clean = config.redact(c, loop)
  assert(clean.name == "[redacted]")
  assert(clean.self == clean, "a self-reference keeps its shape by identity")

  local deep, at = {}, nil
  at = deep
  for _ = 1, 20 do at.down = {}; at = at.down end
  at.leaf = "sk-live-abcdef"
  local scrubbed = config.redact(c, deep)
  local walk, steps = scrubbed, 0
  while type(walk) == "table" and walk.down ~= nil do walk = walk.down; steps = steps + 1 end
  assert(walk == "<deep>", "the copy stops at the cap: " .. tostring(walk))
  assert(steps == 16, "sixteen levels are copied, and then it says so: " .. steps)

  local withfn = config.redact(c, { f = function () end, t = coroutine.create(function () end) })
  assert(withfn.f == "<function>", tostring(withfn.f))
  assert(withfn.t == "<thread>", tostring(withfn.t))
end

function T.an_empty_secret_variable_is_unset()
  local c = assert(config.load { port = { env = env_double { PI_API_KEY = "" } } })
  assert(config.secret(c, "key") == nil, "an empty variable is unset, at every layer")
  assert(warning_about(c, "PI_API_KEY"), table.concat(c.warnings, " | "))
  local shown = nil
  for _, line in ipairs(config.report(c)) do
    if line:match("^key%s") then shown = line end
  end
  assert(shown and shown:find("(secret, unset)", 1, true), tostring(shown))
  assert(not holds(c, '""'), "and no bearer token of the empty string anywhere")
end

function T.a_secret_alias_says_which_one_won()
  local first, second = "sk-live-first", "sk-live-second"
  local c = assert(config.load {
    port = { env = env_double { PI_API_KEY = first, OPENROUTER_API_KEY = second } },
  })
  assert(config.secret(c, "key") == first, "the names are tried in order")
  local why = config.explain(c, "key")
  assert(why.layer == "env" and why.where == "PI_API_KEY", render(why))
  assert(why.redacted == true and why.value == nil and why.raw == nil)
  assert(#why.shadowed == 1 and why.shadowed[1].where == "OPENROUTER_API_KEY", render(why))
  assert(why.shadowed[1].raw == nil, "by name only")
  assert(not holds(why, first) and not holds(why, second), render(why))
end

function T.a_missing_optional_file_is_not_a_failure()
  local fs = fs_double {}
  local c = assert(config.load { path = ".malleable/agent.conf", port = { fs = fs } })
  assert(config.get(c, "budget") == 24, "a fresh checkout with no config must start")
  assert(warning_about(c, ".malleable/agent.conf"), table.concat(c.warnings, " | "))
  assert(#fs.read_paths == 1)
end

function T.a_denied_file_is_a_failure()
  for _, code in ipairs({ "denied", "too_big", "timeout" }) do
    local fs = fs_double({}, { [".malleable/agent.conf"] = code })
    local c, problems = config.load { path = ".malleable/agent.conf", port = { fs = fs } }
    assert(c == nil, "the harness does not fall back to defaults: " .. code)
    local p = problem_with(problems, "unreadable")
    assert(p.message:find(code, 1, true), p.message)
    assert(p.message:find(".malleable/agent.conf", 1, true), p.message)
  end
end

function T.a_required_missing_file_is_a_failure()
  local fs = fs_double {}
  local c, problems = config.load {
    files = { { where = "must.conf", path = "must.conf", required = true } },
    port = { fs = fs },
  }
  assert(c == nil)
  local p = problem_with(problems, "unreadable")
  assert(p.message:find("not_found", 1, true), p.message)
end

function T.a_file_that_will_not_parse_applies_none_of_itself()
  local text = "budget = 12\ntimeout = 30\n-- fine so far\nattempts = 2\nthis line is not a setting\n"
  local c, problems = config.load { text = text }
  assert(c == nil)
  local p = problem_with(problems, "malformed")
  assert(p.where == "line 5", tostring(p.where))
  local again = assert(config.load {})
  assert(config.get(again, "budget") == 24, "nothing leaked through from the file that failed")
  -- and a later file is still parsed, so one run shows every problem
  local _, both = config.load {
    files = { { where = "a", text = "nope\n" }, { where = "b", text = "budgt = 4\n" } },
  }
  assert(problem_with(both, "malformed").layer == "file:a")
  assert(problem_with(both, "unknown_setting").layer == "file:b")
end

function T.a_typo_in_a_file_key_is_not_silence()
  local c, problems = config.load { text = "budgt = 4\n" }
  assert(c == nil)
  local p = problem_with(problems, "unknown_setting")
  assert(p.setting == "budgt" and p.where == "line 1", render(p))
  assert(p.message:find("budget", 1, true), p.message)
end

function T.a_typo_in_a_prefixed_variable_is_not_silence()
  local c, problems = config.load {
    port = { env = env_double { PI_MODLE = "x", PI_API_KEY = "sk-live-abcdef", HOME = "/somewhere" } },
  }
  assert(c == nil, "a variable doing nothing at all, silently, forever, is what this refuses")
  assert(#problems == 1, render(problems))
  local p = problem_with(problems, "unknown_env")
  assert(p.where == "PI_MODLE", tostring(p.where))
  assert(p.message:find("model", 1, true), p.message)
  assert(not p.message:find("HOME", 1, true), p.message)
  -- a declared secret alias and an unprefixed variable are both left alone
  local ok = assert(config.load {
    port = { env = env_double { PI_API_KEY = "sk-live-abcdef", HOME = "/somewhere",
                                OPENROUTER_API_KEY = "sk-live-other" } },
  })
  assert(config.secret(ok, "key") == "sk-live-abcdef")
end

function T.the_typo_scan_degrades_to_a_warning()
  local c = assert(config.load {
    port = { env = env_double({ PI_MODLE = "x" }, { no_names = true }) },
  })
  assert(warning_about(c, "misspelt"), table.concat(c.warnings, " | "))
  assert(config.get(c, "budget") == 24)
  -- a names() that raises degrades the same way rather than taking the load down
  local raisy = assert(config.load {
    port = { env = env_double({ PI_MODLE = "x" }, { names_raise = true }) },
  })
  assert(warning_about(raisy, "misspelt") or warning_about(raisy, "listed"),
    table.concat(raisy.warnings, " | "))
end

function T.a_duplicate_key_is_a_problem_not_last_wins()
  local c, problems = config.load { text = "budget = 12\ntimeout = 5\nbudget = 4\n" }
  assert(c == nil, "last-one-wins is how a file grows two truths that both look right in a diff")
  local p = problem_with(problems, "duplicate")
  assert(p.where == "line 3", tostring(p.where))
  assert(p.message:find("line 1", 1, true) and p.message:find("line 3", 1, true), p.message)
  -- the same key in the base and in a profile is legal
  local ok = assert(config.load { text = "budget = 12\n[profile.review]\nbudget = 4\n", profile = "review" })
  assert(config.get(ok, "budget") == 4)
end

function T.an_out_of_range_value_is_never_clamped()
  local c, problems = config.load { text = "budget = 0\n" }
  assert(c == nil, "a budget of 0 silently becoming 1 is a lie about what is running")
  local p = problem_with(problems, "out_of_range")
  assert(p.setting == "budget" and p.message:find("at least 1", 1, true), p.message)

  local c2, problems2 = config.load { text = "approve = maybe\n" }
  assert(c2 == nil)
  local p2 = problem_with(problems2, "out_of_range")
  for _, allowed in ipairs({ "ask", "allow", "deny" }) do
    assert(p2.message:find(allowed, 1, true), p2.message)
  end
  -- an override is a Lua literal at a call site, so that one raises instead
  assert(raised(config.load, { override = { budget = 0 } }))
end

function T.a_profile_cannot_select_a_profile()
  local text = "budget = 1\n[profile.review]\nprofile = other\nbudget = 2\n[profile.other]\nbudget = 3\n"
  local c, problems = config.load { text = text, profile = "review" }
  assert(c == nil, "otherwise a file could be written that never settles")
  local p = problem_with(problems, "not_allowed")
  assert(p.where == "line 3", tostring(p.where))
  assert(p.setting == "profile")
end

function T.a_profile_nobody_declared_is_named_and_refused()
  local text = "[profile.review]\nbudget = 2\n"
  local c, problems = config.load { text = text, profile = "revew" }
  assert(c == nil, "a typo'd profile silently running the defaults is the bug this is against")
  local p = problem_with(problems, "no_such_profile")
  assert(p.message:find("revew", 1, true) and p.message:find("review", 1, true), p.message)

  local c2, problems2 = config.load {
    text = text,
    port = { env = env_double { PI_PROFILE = "revew" } },
  }
  assert(c2 == nil)
  assert(problem_with(problems2, "no_such_profile").message:find("review", 1, true))

  -- opts.profile is applied as a profile value in the override layer, so a profile
  -- written straight into `override` is the same statement made another way: it selects,
  -- and a typo in it is refused rather than silently running the defaults
  local c3, problems3 = config.load { text = text, override = { profile = "revew" } }
  assert(c3 == nil, "a typo'd profile in an override is the same bug by another door")
  assert(problem_with(problems3, "no_such_profile").message:find("review", 1, true))
  local ok = assert(config.load { text = text, override = { profile = "review" } })
  assert(ok.profile == "review" and config.get(ok, "budget") == 2)
  assert(config.explain(ok, "profile").layer == "override",
    "and explain names the layer that chose it")
end

function T.a_config_file_is_text_and_never_code()
  local fs = fs_double { ["a.conf"] = table.concat({
    'model = os.execute("touch /tmp/x")',
    "budget = 2 + 2",
    "workspace = ${HOME}/etc",
    "",
  }, "\n") }
  local c, problems = config.load { path = "a.conf", port = { fs = fs } }
  assert(c == nil, "budget is wrong_type, so the load reports rather than resolves")
  assert(problem_with(problems, "wrong_type").setting == "budget")
  -- with the number gone, the rest are exactly the strings that were written
  local ok = assert(config.load {
    text = 'model = os.execute("touch /tmp/x")\nworkspace = ${HOME}/etc\n',
  })
  assert(config.get(ok, "model") == 'os.execute("touch /tmp/x")', config.get(ok, "model"))
  assert(config.get(ok, "workspace") == "${HOME}/etc", config.get(ok, "workspace"))
  assert(#fs.wrote == 0 and #fs.read_paths == 1, "the doubles recorded nothing but the one read")
end

function T.a_hostile_file_cannot_cost_unbounded_work()
  local many = {}
  for i = 1, 5000 do many[i] = "budget = " .. i end
  local c, problems = config.load { text = table.concat(many, "\n") }
  assert(c == nil)
  local p = problem_with(problems, "too_big")
  assert(p.message:find("5000", 1, true) and p.message:find("4096", 1, true), p.message)

  local comments = {}
  for i = 1, 4000 do comments[i] = "-- nothing here" end
  local tree = assert(config.parse(table.concat(comments, "\n")))
  assert(#tree.base == 0 and next(tree.profiles) == nil)

  local long = assert(config.parse("workspace = " .. string.rep("x", 100000) .. "\n"))
  assert(#long.base[1].raw == 100000)
  local quoted = assert(config.parse('workspace = "' .. string.rep("y", 100000) .. '"\n'))
  assert(#quoted.base[1].raw == 100000)
end

function T.a_port_that_raises_becomes_a_problem_not_a_stack_trace()
  local c = assert(config.load { port = { env = env_double({}, { raises = true }) } })
  assert(config.get(c, "budget") == 24, "a broken environment port degrades to a stated gap")
  assert(warning_about(c, "PI_BUDGET"), table.concat(c.warnings, " | "))

  local c2, problems = config.load {
    path = "a.conf",
    port = { fs = fs_double({}, nil, { raises = true }) },
  }
  assert(c2 == nil)
  assert(problem_with(problems, "unreadable").message:find("a.conf", 1, true))
end

function T.a_missing_port_raises_but_a_missing_value_does_not()
  local bad, message = raised(config.load, { env = true })
  assert(bad, "a host that wired no environment port and asked for the layer has a wiring bug")
  assert(message:find("port.env.get", 1, true), message)
  local bad2, message2 = raised(config.load, { path = "a.conf" })
  assert(bad2 and message2:find("port.fs.read", 1, true), message2)

  local c = assert(config.load { port = { env = env_double {} } })
  assert(config.get(c, "budget") == 24, "every variable unset is a world condition, and it loads")
  assert(config.secret(c, "key") == nil)
end

function T.wrong_shapes_raise_and_name_the_argument()
  local c = assert(config.load())
  local checks = {
    { fn = function () return config.load(7) end, says = "opts" },
    { fn = function () return config.load { overrides = {} } end, says = "override" },
    { fn = function () return config.get(c, nil) end, says = "name" },
    { fn = function () return config.get(c, "nope") end, says = "nope" },
    { fn = function () return config.secret(c, "budget") end, says = "not a secret" },
    { fn = function () return config.schema { { name = "x" } } end, says = "about" },
    { fn = function () return config.schema { { name = "X", kind = "string", about = "a" } } end, says = "name" },
    { fn = function () return config.schema {
        { name = "a", kind = "string", about = "one", env = "PI_MODEL" },
        { name = "b", kind = "string", about = "two", env = "PI_MODEL" },
      } end, says = "PI_MODEL" },
    { fn = function () return config.schema {
        { name = "a", kind = "string", about = "one" },
        { name = "a", kind = "string", about = "two" },
      } end, says = "twice" },
    { fn = function () return config.schema { { name = "a", kind = "colour", about = "one" } } end, says = "kind" },
    { fn = function () return config.schema { { name = "a", kind = "number", about = "one", default = "x" } } end, says = "default" },
    { fn = function () return config.load { schema = { { name = "a" } } } end, says = "config.schema" },
    { fn = function () return config.parse(7) end, says = "text" },
    { fn = function () return config.get({}, "budget") end, says = "config" },
  }
  for i = 1, #checks do
    local bad, message = raised(checks[i].fn)
    assert(bad, "check " .. i .. " should have raised")
    assert(message:find(checks[i].says, 1, true), "check " .. i .. ": " .. message)
  end
  -- and a config is read-only after it is resolved
  assert(raised(function () c.profile = "sneaky" end))
end

function T.a_secret_schema_that_breaks_a_rule_raises()
  local broken = {
    { { name = "k", kind = "string", about = "a", secret = true, env = "K", default = "sk-live" } },
    { { name = "k", kind = "number", about = "a", secret = true, env = "K" } },
    { { name = "k", kind = "string", about = "a", secret = true } },
    { { name = "k", kind = "string", about = "a", secret = true, env = "K", one_of = { "sk-live" } } },
    { { name = "k", kind = "string", about = "a", secret = true, env = "K", file = true } },
  }
  for i = 1, #broken do
    local bad, message = raised(config.schema, broken[i])
    assert(bad, "definition " .. i .. " should have been refused before any value existed to leak")
    assert(message:find("k", 1, true), message)
  end
  -- a secret has file forced to false, and reads back the same way twice
  local s = config.schema { { name = "k", kind = "string", about = "a", secret = true, env = "K" } }
  assert(s.by_name.k.file == false and s.by_name.k.secret == true)
  local again = config.schema(s)
  assert(again.by_name.k.file == false and again.by_name.k.env[1] == "K")
  assert(#again.settings == #s.settings)
end

function T.two_configs_in_one_process_cannot_see_each_other()
  local one = assert(config.load {
    port = { env = env_double { PI_API_KEY = "sk-live-one", PI_BUDGET = "2" } },
  })
  local other_schema = config.schema {
    { name = "budget", kind = "number", about = "steps", default = 5, env = "PI_BUDGET" },
    { name = "token", kind = "string", about = "a credential", secret = true, env = "OTHER_TOKEN" },
  }
  local two = assert(config.load {
    schema = other_schema,
    port = { env = env_double { OTHER_TOKEN = "sk-live-two" } },
  })
  assert(config.get(one, "budget") == 2 and config.get(two, "budget") == 5)
  assert(config.secret(one, "key") == "sk-live-one")
  assert(config.secret(two, "token") == "sk-live-two")
  assert(raised(config.secret, one, "token"))
  assert(raised(config.get, two, "workspace"))
  assert(not holds(config.explain(two, "token"), "sk-live-two"))
  two = nil
  collectgarbage()
  collectgarbage()
  assert(config.secret(one, "key") == "sk-live-one", "dropping one does not disturb the other")
end

function T.nothing_it_was_given_is_mutated()
  local defs = {
    { name = "budget", kind = "number", about = "steps", default = 5, min = 1, env = "PI_BUDGET" },
    { name = "tools", kind = "list", about = "the tool names", default = { "read" }, env = "PI_TOOLS" },
  }
  local files = { { where = "a.conf", text = "budget = 3\ntools = read, write\n" } }
  local override = { budget = 2 }
  local opts = {
    schema = config.schema(defs), files = files, override = override,
    port = { env = env_double { PI_TOOLS = "read" } },
  }
  -- the port is left out of the comparison: this test's own double records what it was
  -- asked for, which is the double changing, not `config` mutating what it was given.
  local function shape_of(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ",")
  end
  local before = { defs = render(defs), files = render(files), override = render(override),
                   opts = shape_of(opts), schema = render(opts.schema) }
  local c = assert(config.load(opts))
  local c2 = config.with(c, { budget = 1 })
  config.public(c)
  config.redact(c, { a = "b" })
  config.report(c2)
  assert(render(defs) == before.defs, render(defs))
  assert(render(files) == before.files, render(files))
  assert(render(override) == before.override, render(override))
  assert(shape_of(opts) == before.opts, shape_of(opts))
  assert(render(opts.schema) == before.schema, "the schema it was handed is untouched")
  -- and what it returns is fresh: mutating it changes nothing
  local pub = config.public(c)
  pub.budget = 99
  assert(config.get(c, "budget") == 2)
  local list = config.get(c, "tools")
  list[1] = "tampered"
  assert(config.get(c, "tools")[1] == "read")
end

local function source_of(name)
  local handle = assert(io.open(here .. "/../src/" .. name, "rb"))
  local body = handle:read("*a")
  handle:close()
  return body
end

-- A mention that is not part of a longer word: "config.load(" is not a reach for load.
local function mentions(body, needle)
  local at = 1
  while true do
    local from = body:find(needle, at, true)
    if not from then return false end
    local before = from > 1 and body:sub(from - 1, from - 1) or " "
    if not before:match("[%w_.]") then return true end
    at = from + 1
  end
end

function T.the_module_touches_nothing_real()
  local body = source_of("config.lua")
  local forbidden = {
    "os.getenv", "os.execute", "os.time", "os.date", "os.clock", "os.remove", "os.rename",
    "math.random", "io.", "loadstring", "dofile", "loadfile", "setfenv",
    "load(", "print(",
  }
  for i = 1, #forbidden do
    assert(not mentions(body, forbidden[i]),
      "src/config.lua reaches for " .. forbidden[i] .. ", and it may not")
  end
end

function T.the_module_requires_no_sibling()
  local body = source_of("config.lua")
  for name in body:gmatch('require%s*[("\']+([%w_./]+)') do
    assert(name == "port", "src/config.lua requires " .. name .. ", and only port is allowed")
  end
end

return T
