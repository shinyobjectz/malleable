-- config: configuration, profiles and secrets.
--
-- Everything the harness needs before it can run arrives from four places -- built-in
-- defaults, any number of configuration files, the environment, and the explicit
-- overrides a host passes in -- and this module is the one that decides which of them
-- wins. Every resolved value can name the layer it came from, because a configuration
-- you cannot explain is one you cannot debug.
--
-- Secrets are the exception that shapes the module: they arrive from the environment
-- and nowhere else, and they never appear in the returned table, in a report, in a
-- problem, in a raised sentence or in `tostring`. The only door they leave by is
-- `config.secret`.
--
-- The two-channel convention, as everywhere in this tree:
--
--   * a wrong shape RAISES  -- a schema, an opts key, a Lua type: the author can see it
--   * a wrong world RETURNS -- nil, problems for a file, a variable or a value
--
-- It reaches nothing real. No environment, no disk, no clock, no subprocess: the
-- environment arrives through `port.env` and a file through `port.fs`, so a whole
-- resolution runs in a test with nothing wired but tables. It requires no other module
-- in this tree.

local config = {}

-- ---------------------------------------------------------------------------
-- Small helpers.

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function trim_left(s)
  return (s:gsub("^%s+", ""))
end

local function has_nul(s)
  return s:find("\0", 1, true) ~= nil
end

-- A number as a person would write it: 24, not 24.0. Only whole numbers a double holds
-- exactly are written with %d: above that, 5.4 refuses the format outright and LuaJIT
-- prints a clamped integer that is not the value, and `report` may do neither -- it
-- cannot raise and it may not lie.
local EXACT = 2 ^ 53
local function numtext(n)
  if n ~= n or n == math.huge or n == -math.huge then return tostring(n) end
  if n == math.floor(n) and n >= -EXACT and n <= EXACT then return string.format("%d", n) end
  return tostring(n)
end

local function valuetext(v)
  local t = type(v)
  if t == "string" then return v end
  if t == "number" then return numtext(v) end
  if t == "boolean" then return v and "true" or "false" end
  if t == "table" then
    local parts = {}
    for i = 1, #v do parts[i] = tostring(v[i]) end
    return table.concat(parts, ", ")
  end
  return tostring(v)
end

local function list_of(t)
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  return out
end

local function is_list(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
    n = n + 1
  end
  return n == #t
end

local function frozen(t, what)
  return setmetatable(t, {
    __metatable = what,
    __newindex = function()
      error(what .. " is read-only", 2)
    end,
  })
end

-- Simple edit distance, used only to suggest the name a typo was reaching for. Bounded
-- by construction: both arguments are truncated, so a hostile variable name cannot buy
-- unbounded work.
local function distance(a, b)
  if #a > 64 then a = a:sub(1, 64) end
  if #b > 64 then b = b:sub(1, 64) end
  if a == b then return 0 end
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local prev, cur = {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    local ca = a:sub(i, i)
    for j = 1, lb do
      local best = prev[j] + 1
      local left = cur[j - 1] + 1
      if left < best then best = left end
      local diag = prev[j - 1] + ((ca == b:sub(j, j)) and 0 or 1)
      if diag < best then best = diag end
      cur[j] = best
    end
    for j = 0, lb do prev[j] = cur[j] end
  end
  return prev[lb]
end

local function closest(name, candidates)
  local best, at = nil, 4
  for i = 1, #candidates do
    local d = distance(name:lower(), candidates[i]:lower())
    if d < at then best, at = candidates[i], d end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- The kinds. There are four, and there will not be a fifth without a line in
-- spec/config.md: a configuration format that grows a type system grows a parser.

local KINDS = { string = true, number = true, boolean = true, list = true }

local function kind_of(v)
  local t = type(v)
  if t == "table" then return "list" end
  return t
end

-- Read a Lua value back out of the text a layer carried. Returns value, or nil plus a
-- sentence fragment naming what the kind wanted.
local function coerce(setting, raw, quoted)
  local kind = setting.kind
  if kind == "string" then
    return raw
  elseif kind == "number" then
    local n = tonumber(raw)
    if n == nil then return nil, "a number" end
    return n
  elseif kind == "boolean" then
    local low = raw:lower()
    if low == "true" or low == "1" then return true end
    if low == "false" or low == "0" then return false end
    return nil, "true, false, 1 or 0"
  end
  -- list: split on commas and trim each part; a quoted value is one element, never split
  if quoted then return { raw } end
  local out = {}
  if trim(raw) ~= "" then
    for part in (raw .. ","):gmatch("([^,]*),") do
      out[#out + 1] = trim(part)
    end
  end
  return out
end

-- Range, membership and nothing else. Returns nil when the value is allowed, or a
-- sentence fragment naming what was allowed.
local function out_of_range(setting, value)
  if setting.one_of then
    for i = 1, #setting.one_of do
      if setting.one_of[i] == value then return nil end
    end
    return "one of " .. table.concat(setting.one_of, ", ")
  end
  if setting.min ~= nil and value < setting.min then
    return "at least " .. numtext(setting.min)
  end
  if setting.max ~= nil and value > setting.max then
    return "at most " .. numtext(setting.max)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- The built-in settings, exported as data so a host extends them rather than
-- reproducing them. Nothing here is required: a declaration file may supply the model,
-- and a config that refused to resolve without one would break every agent that
-- already says what model it wants.

config.settings = {
  { name = "model", kind = "string", about = "the model id to call",
    env = "PI_MODEL" },
  { name = "base_url", kind = "string", about = "the endpoint the adapter should call",
    env = "PI_BASE_URL" },
  { name = "profile", kind = "string", about = "the profile section a configuration file should apply",
    env = "PI_PROFILE" },
  { name = "budget", kind = "number", default = 24, min = 1,
    about = "the most steps one run may take", env = "PI_BUDGET" },
  { name = "timeout", kind = "number", default = 60, min = 1,
    about = "seconds allowed for one model call", env = "PI_TIMEOUT" },
  { name = "attempts", kind = "number", default = 3, min = 1, max = 10,
    about = "how many times a failed call is tried again", env = "PI_ATTEMPTS" },
  { name = "workspace", kind = "string", default = ".",
    about = "the directory a run may read and write", env = "PI_WORKSPACE" },
  { name = "approve", kind = "string", default = "ask", one_of = { "ask", "allow", "deny" },
    about = "what to do when a tool asks for permission", env = "PI_APPROVE" },
  { name = "log_level", kind = "string", default = "info",
    one_of = { "debug", "info", "warn", "error" },
    about = "the lowest level a log line is written at", env = "PI_LOG_LEVEL" },
  { name = "key", kind = "string", secret = true,
    about = "the credential the provider adapter authenticates with",
    env = { "PI_API_KEY", "OPENROUTER_API_KEY" } },
}

-- ---------------------------------------------------------------------------
-- config.schema

local DEF_KEYS = {
  name = true, kind = true, default = true, about = true, env = true,
  one_of = true, min = true, max = true, secret = true, required = true, file = true,
}

local function schema_error(what, ...)
  error("config.schema: " .. string.format(what, ...), 4)
end

local function normalise(def, at)
  if type(def) ~= "table" then
    schema_error("definition %d is a table, got %s", at, type(def))
  end
  local name = def.name
  if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") then
    schema_error("definition %d has no usable `name`; it is lowercase letters, digits and underscores, got %s",
      at, tostring(name))
  end
  for k in pairs(def) do
    if not DEF_KEYS[k] then
      schema_error("%s declares `%s`, which is not part of a setting", name, tostring(k))
    end
  end
  if type(def.about) ~= "string" or trim(def.about) == "" then
    schema_error("%s has no `about`; a setting nobody can read is a setting nobody can set", name)
  end
  if type(def.kind) ~= "string" or not KINDS[def.kind] then
    schema_error("%s has kind %s; the kinds are string, number, boolean and list", name, tostring(def.kind))
  end

  local out = {
    name = name,
    kind = def.kind,
    about = def.about,
    secret = def.secret == true,
    required = def.required == true,
  }
  if def.secret ~= nil and type(def.secret) ~= "boolean" then
    schema_error("%s has a `secret` that is not a boolean", name)
  end
  if def.required ~= nil and type(def.required) ~= "boolean" then
    schema_error("%s has a `required` that is not a boolean", name)
  end
  if def.file ~= nil and type(def.file) ~= "boolean" then
    schema_error("%s has a `file` that is not a boolean", name)
  end

  -- env: a name, or a list of names tried in order
  local env = {}
  if def.env ~= nil then
    if type(def.env) == "string" then
      env[1] = def.env
    elseif is_list(def.env) then
      for i = 1, #def.env do
        if type(def.env[i]) ~= "string" or def.env[i] == "" then
          schema_error("%s has an `env` entry that is not a variable name", name)
        end
        env[i] = def.env[i]
      end
    else
      schema_error("%s has an `env` that is neither a name nor a list of names", name)
    end
  end
  out.env = env

  if def.one_of ~= nil then
    if def.kind ~= "string" then
      schema_error("%s has a `one_of`, which belongs to kind string, not %s", name, def.kind)
    end
    if not is_list(def.one_of) or #def.one_of == 0 then
      schema_error("%s has a `one_of` that is not a non-empty list", name)
    end
    out.one_of = {}
    for i = 1, #def.one_of do
      if type(def.one_of[i]) ~= "string" then
        schema_error("%s has a `one_of` entry that is not a string", name)
      end
      out.one_of[i] = def.one_of[i]
    end
  end

  for _, bound in ipairs({ "min", "max" }) do
    if def[bound] ~= nil then
      if def.kind ~= "number" then
        schema_error("%s has a `%s`, which belongs to kind number, not %s", name, bound, def.kind)
      end
      if type(def[bound]) ~= "number" then
        schema_error("%s has a `%s` that is not a number", name, bound)
      end
      out[bound] = def[bound]
    end
  end
  if out.min ~= nil and out.max ~= nil and out.min > out.max then
    schema_error("%s has a `min` above its `max`", name)
  end

  -- The five secret rules, checked here so a schema that breaks one dies before any
  -- value exists to leak.
  if out.secret then
    if out.kind ~= "string" then
      schema_error("%s is a secret, so its kind is string, not %s", name, out.kind)
    end
    if #out.env == 0 then
      schema_error("%s is a secret, so it names at least one environment variable", name)
    end
    if def.default ~= nil then
      schema_error("%s is a secret and has a default; a default credential is not a thing", name)
    end
    if out.one_of ~= nil or out.min ~= nil or out.max ~= nil then
      schema_error("%s is a secret, so it has no one_of, min or max", name)
    end
    if def.file == true then
      schema_error("%s is a secret, so it cannot be read from a configuration file", name)
    end
    out.file = false
  else
    out.file = def.file ~= false
  end

  if def.default ~= nil then
    if kind_of(def.default) ~= out.kind then
      schema_error("%s wants a default of kind %s, got %s", name, out.kind, kind_of(def.default))
    end
    if out.kind == "list" then
      if not is_list(def.default) then
        schema_error("%s has a default that is not a list", name)
      end
      local copy = {}
      for i = 1, #def.default do
        if type(def.default[i]) ~= "string" then
          schema_error("%s has a default list holding something that is not a string", name)
        end
        copy[i] = def.default[i]
      end
      out.default = copy
    else
      out.default = def.default
    end
    local wanted = out_of_range(out, out.default)
    if wanted then
      schema_error("%s has a default of %s, and it wants %s", name, valuetext(out.default), wanted)
    end
  end

  return frozen(out, "a setting")
end

local function is_schema(s)
  return getmetatable(s) == "config.schema"
end

function config.schema(defs)
  if defs == nil then defs = config.settings end
  if is_schema(defs) then defs = defs.settings end
  if type(defs) ~= "table" or not is_list(defs) then
    error("config.schema: `defs` is a list of setting definitions, got " .. type(defs), 2)
  end

  local settings, by_name, by_env = {}, {}, {}
  for i = 1, #defs do
    local s = normalise(defs[i], i)
    if by_name[s.name] then
      error(string.format("config.schema: %s is declared twice", s.name), 2)
    end
    by_name[s.name] = s
    for j = 1, #s.env do
      local claimed = by_env[s.env[j]]
      if claimed then
        error(string.format("config.schema: %s and %s both claim the variable %s",
          claimed.name, s.name, s.env[j]), 2)
      end
      by_env[s.env[j]] = s
    end
    settings[#settings + 1] = s
  end
  table.sort(settings, function (a, b) return a.name < b.name end)

  local names = {}
  for i = 1, #settings do names[i] = settings[i].name end

  return frozen({
    settings = frozen(settings, "a schema"),
    by_name = frozen(by_name, "a schema"),
    by_env = frozen(by_env, "a schema"),
    names = frozen(names, "a schema"),
  }, "config.schema")
end

-- ---------------------------------------------------------------------------
-- config.parse -- the file format.
--
-- Text that is parsed, never code that is run. There is no expression, no
-- interpolation, no include, no environment substitution and no arithmetic, so a
-- hostile configuration file has nothing to be hostile with. `parse` knows nothing
-- about settings, so an unknown key is not its problem; it reports only what is not a
-- well-formed file.

local MAX_LINES = 4096

local function problem(code, message, at, extra)
  local p = { code = code, message = message }
  if at then p.where = "line " .. at end
  if extra then
    for k, v in pairs(extra) do p[k] = v end
  end
  return p
end

-- Read a quoted value out of `s`, which starts at its opening quote. Returns the text,
-- or nil plus a sentence fragment saying what was expected.
local function read_quoted(s)
  local parts, i, n = {}, 2, #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == '"' then
      if trim(s:sub(i + 1)) ~= "" then
        return nil, "nothing after the closing quote; there is no trailing comment"
      end
      return table.concat(parts)
    elseif ch == "\\" then
      local esc = s:sub(i + 1, i + 1)
      if esc == "\\" then parts[#parts + 1] = "\\"
      elseif esc == '"' then parts[#parts + 1] = '"'
      elseif esc == "n" then parts[#parts + 1] = "\n"
      elseif esc == "t" then parts[#parts + 1] = "\t"
      else
        return nil, "an escape of \\\\, \\\", \\n or \\t"
      end
      i = i + 2
    else
      local j = s:find('[\\"]', i)
      if not j then
        parts[#parts + 1] = s:sub(i)
        i = n + 1
      else
        parts[#parts + 1] = s:sub(i, j - 1)
        i = j
      end
    end
  end
  return nil, "a closing quote"
end

function config.parse(text)
  if type(text) ~= "string" then
    error("config.parse: `text` is a string, got " .. type(text), 2)
  end

  local lines, at, n = {}, 1, #text
  while at <= n do
    local nl = text:find("\n", at, true)
    if nl then
      lines[#lines + 1] = text:sub(at, nl - 1)
      at = nl + 1
    else
      lines[#lines + 1] = text:sub(at)
      at = n + 1
    end
  end

  if #lines > MAX_LINES then
    return nil, { problem("too_big",
      string.format("the file is %d lines, over the limit of %d", #lines, MAX_LINES),
      MAX_LINES + 1, { count = #lines }) }
  end

  local tree = { base = {}, profiles = {} }
  local problems = {}
  local section, target = "", tree.base
  local seen = { [""] = {} }

  for at_line = 1, #lines do
    local line = lines[at_line]
    if line:sub(-1) == "\r" then line = line:sub(1, #line - 1) end
    local body = trim_left(line)

    if body == "" then                                    -- nothing at all
      if has_nul(line) then
        problems[#problems + 1] = problem("malformed", "there is a zero byte outside a quoted value", at_line)
      end
    elseif body:sub(1, 2) == "--" then                     -- a whole-line comment
      if has_nul(body) then
        problems[#problems + 1] = problem("malformed", "there is a zero byte outside a quoted value", at_line)
      end
    elseif body:sub(1, 1) == "[" then                      -- a section header
      if has_nul(body) then
        problems[#problems + 1] = problem("malformed", "there is a zero byte outside a quoted value", at_line)
      else
        local name = trim(body):match("^%[profile%.([a-z][a-z0-9_%-]*)%]$")
        if name then
          section = name
          if not tree.profiles[name] then
            tree.profiles[name] = {}
            seen[name] = {}
          end
          target = tree.profiles[name]
        else
          problems[#problems + 1] = problem("unknown_section",
            string.format("%s is not a section; a section header is [profile.<name>]", trim(body)), at_line)
        end
      end
    else                                                   -- a key and a value
      local key, rest = body:match("^([a-z][a-z0-9_]*)%s*=(.*)$")
      if not key then
        problems[#problems + 1] = problem("malformed",
          "expected a comment, a section header, or `key = value` with a lowercase key", at_line)
      else
        rest = trim_left(rest)
        local raw, quoted, wanted
        if rest:sub(1, 1) == '"' then
          raw, wanted = read_quoted(rest)
          quoted = true
        else
          raw = trim(rest)
          quoted = false
          if has_nul(raw) then
            raw, wanted = nil, "a value without a zero byte in it"
          end
        end
        if raw == nil then
          problems[#problems + 1] = problem("malformed",
            string.format("the value of %s wants %s", key, wanted), at_line)
        else
          local before = seen[section][key]
          if before then
            problems[#problems + 1] = problem("duplicate",
              string.format("%s is set twice in the same section, at line %d and line %d",
                key, before, at_line), at_line, { setting = key })
          else
            seen[section][key] = at_line
            target[#target + 1] = { key = key, raw = raw, line = at_line, quoted = quoted }
          end
        end
      end
    end
  end

  if #problems > 0 then return nil, problems end
  return tree
end

-- The profile names a parse tree declares, sorted.
local function declared_in(tree)
  local out = {}
  for name in pairs(tree.profiles) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------------------
-- The resolved store.
--
-- The values do not live in `c`. They live here, keyed by `c` itself and weak in that
-- key, so a dropped config is collectable. This is not decoration: it means pairs(c),
-- a JSON encoder walking c, a debug print, a deep copy into a session file and a crash
-- dump all see four fields and no credential.

local store = setmetatable({}, { __mode = "k" })

local function state(c, where)
  local st = store[c]
  if st == nil then
    error(where .. ": `c` is a config from config.load, got " .. type(c), 3)
  end
  return st
end

local function copy_value(v)
  if type(v) == "table" then return list_of(v) end
  return v
end

local OPT_KEYS = {
  schema = true, files = true, text = true, path = true, env = true,
  env_prefix = true, profile = true, override = true, port = true,
}

local FILE_KEYS = { where = true, text = true, path = true, required = true }

-- Every override, wherever it came from, is checked the same way, and every one of
-- these is a mistake an author can see at the call site -- so every one raises.
local function check_override(where, schema, override)
  if type(override) ~= "table" then
    error(where .. ": `override` is a table of setting names to values, got " .. type(override), 3)
  end
  for k, v in pairs(override) do
    if type(k) ~= "string" then
      error(where .. ": `override` is keyed by setting name, got a " .. type(k) .. " key", 3)
    end
    local s = schema.by_name[k]
    if not s then
      local near = closest(k, schema.names)
      error(where .. ": there is no setting called " .. k ..
        (near and (" -- did you mean " .. near .. "?") or ""), 3)
    end
    if s.secret then
      error(where .. ": " .. k ..
        " is a secret, and a secret comes from the environment; name a variable in the schema", 3)
    end
    if kind_of(v) ~= s.kind then
      error(where .. ": " .. k .. " wants " .. s.kind .. ", got " .. kind_of(v), 3)
    end
    if s.kind == "list" then
      if not is_list(v) then
        error(where .. ": " .. k .. " wants a list of strings", 3)
      end
      for i = 1, #v do
        if type(v[i]) ~= "string" then
          error(where .. ": " .. k .. " wants a list of strings, and element " .. i ..
            " is a " .. type(v[i]), 3)
        end
      end
    end
    local wanted = out_of_range(s, v)
    if wanted then
      error(where .. ": " .. k .. " was given " .. valuetext(v) .. ", and it wants " .. wanted, 3)
    end
  end
end

-- Build the four-field table a caller gets back, and hide everything else.
local function finish(st)
  local c = setmetatable({
    profile = st.profile,
    layers = st.layers,
    warnings = st.warnings,
    schema = st.schema,
  }, {
    __metatable = "config",
    __newindex = function ()
      error("a config is read-only after it is resolved; call config.with for another", 2)
    end,
    __tostring = function (self)
      return string.format("config(profile=%s, layers=%d)", self.profile or "nil", #self.layers)
    end,
  })
  store[c] = st
  return c
end

-- Count what each layer actually won, so an empty layer is visibly empty. Counted by
-- the layer's position, never by its name: two `files` entries may carry the same
-- `where`, and counting by name would credit each of the two layers with what both won.
local function tally(st)
  local won = {}
  for _, v in pairs(st.values) do
    if v.at then won[v.at] = (won[v.at] or 0) + 1 end
  end
  for _, m in pairs(st.secret_meta) do
    if m.at then won[m.at] = (won[m.at] or 0) + 1 end
  end
  for i = 1, #st.layers do
    local l = st.layers[i]
    l.n = won[i] or 0
    frozen(l, "a layer")
  end
  frozen(st.layers, "the layers")
  frozen(st.warnings, "the warnings")
end

-- ---------------------------------------------------------------------------
-- config.load

function config.load(opts)
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then
    error("config.load: `opts` is a table or nil, got " .. type(opts), 2)
  end
  for k in pairs(opts) do
    if not OPT_KEYS[k] then
      local near = closest(tostring(k), { "schema", "files", "text", "path", "env",
        "env_prefix", "profile", "override", "port" })
      error("config.load: `opts` has no " .. tostring(k) ..
        (near and (" -- did you mean " .. near .. "?") or ""), 2)
    end
  end

  local schema = opts.schema
  if schema == nil then
    schema = config.schema(config.settings)
  elseif not is_schema(schema) then
    error("config.load: `schema` comes from config.schema, got " .. type(schema), 2)
  end

  if opts.port ~= nil and type(opts.port) ~= "table" then
    error("config.load: `port` is a table of capability ports, got " .. type(opts.port), 2)
  end
  local ports = opts.port or {}

  local prefix = opts.env_prefix
  if prefix == nil then prefix = "PI_" end
  if type(prefix) ~= "string" then
    error("config.load: `env_prefix` is a string or nil, got " .. type(prefix), 2)
  end

  local env_on
  if opts.env == nil then
    env_on = type(ports.env) == "table"
  elseif type(opts.env) == "boolean" then
    env_on = opts.env
  else
    error("config.load: `env` is a boolean or nil, got " .. type(opts.env), 2)
  end
  if env_on then
    if type(ports.env) ~= "table" or type(ports.env.get) ~= "function" then
      error("config.load: the environment layer needs `port.env.get`, and none was wired", 2)
    end
  end

  if opts.override ~= nil then check_override("config.load", schema, opts.override) end
  if opts.profile ~= nil and type(opts.profile) ~= "string" then
    error("config.load: `profile` is a string or nil, got " .. type(opts.profile), 2)
  end
  if opts.profile ~= nil and opts.override ~= nil and opts.override.profile ~= nil then
    error("config.load: the profile is given twice, once as `profile` and once in `override`", 2)
  end
  if opts.profile ~= nil and not schema.by_name.profile then
    error("config.load: `profile` was given, and this schema has no profile setting", 2)
  end

  local problems, warnings = {}, {}

  -- The file entries, in the order they will be applied: `files` first, then the `text`
  -- shorthand, then the `path` shorthand.
  local entries = {}
  if opts.files ~= nil then
    if not is_list(opts.files) then
      error("config.load: `files` is a list of entries, lowest priority first, got " .. type(opts.files), 2)
    end
    for i = 1, #opts.files do
      local e = opts.files[i]
      if type(e) ~= "table" then
        error("config.load: files entry " .. i .. " is a table, got " .. type(e), 2)
      end
      for k in pairs(e) do
        if not FILE_KEYS[k] then
          error("config.load: files entry " .. i .. " has no " .. tostring(k), 2)
        end
      end
      if e.text ~= nil and e.path ~= nil then
        error("config.load: files entry " .. i .. " names both a text and a path", 2)
      end
      if e.text ~= nil then
        if type(e.text) ~= "string" then
          error("config.load: files entry " .. i .. " has a `text` that is not a string", 2)
        end
        if type(e.where) ~= "string" or e.where == "" then
          error("config.load: files entry " .. i .. " has a `text` and needs a `where` to name it", 2)
        end
        entries[#entries + 1] = { where = e.where, text = e.text }
      elseif e.path ~= nil then
        if type(e.path) ~= "string" then
          error("config.load: files entry " .. i .. " has a `path` that is not a string", 2)
        end
        entries[#entries + 1] = { where = e.where or e.path, path = e.path, required = e.required == true }
      else
        error("config.load: files entry " .. i .. " is neither a `text` nor a `path`", 2)
      end
    end
  end
  if opts.text ~= nil then
    if type(opts.text) ~= "string" then
      error("config.load: `text` is a string or nil, got " .. type(opts.text), 2)
    end
    entries[#entries + 1] = { where = "(text)", text = opts.text }
  end
  if opts.path ~= nil then
    if type(opts.path) ~= "string" then
      error("config.load: `path` is a string or nil, got " .. type(opts.path), 2)
    end
    entries[#entries + 1] = { where = opts.path, path = opts.path, required = false }
  end

  -- Read the ones that come off a filesystem. Every port call is under pcall: a broken
  -- port must not take the load down with a stack trace.
  for i = 1, #entries do
    local e = entries[i]
    if e.path then
      local read = ports.fs and ports.fs.read
      if type(read) ~= "function" then
        error("config.load: reading " .. e.path .. " needs `port.fs.read`, and none was wired", 2)
      end
      local ok, text, err = pcall(read, e.path)
      if not ok then
        problems[#problems + 1] = problem("unreadable",
          string.format("reading %s raised: %s", e.path, tostring(text)), nil,
          { layer = "file:" .. e.where })
      elseif text == nil then
        local code = (type(err) == "table" and type(err.code) == "string") and err.code or "unavailable"
        local said = (type(err) == "table" and type(err.message) == "string") and err.message or code
        if code == "not_found" and not e.required then
          warnings[#warnings + 1] = string.format("there is no %s; the defaults stand where it would have spoken", e.path)
        else
          problems[#problems + 1] = problem("unreadable",
            string.format("%s could not be read (%s): %s", e.path, code, said), nil,
            { layer = "file:" .. e.where })
        end
      elseif type(text) ~= "string" then
        problems[#problems + 1] = problem("unreadable",
          string.format("%s came back as a %s rather than text", e.path, type(text)), nil,
          { layer = "file:" .. e.where })
      else
        e.text = text
      end
    end
  end

  -- Parse. A file that will not parse applies none of itself, not even the lines that
  -- parsed, and the other files are still parsed so one run shows every problem.
  local files = {}
  for i = 1, #entries do
    local e = entries[i]
    if e.text ~= nil then
      local tree, bad = config.parse(e.text)
      if tree then
        files[#files + 1] = { where = e.where, tree = tree }
      else
        for j = 1, #bad do
          local p = bad[j]
          p.layer = "file:" .. e.where
          if p.code == "too_big" then
            p.message = string.format("%s is %d lines, over the limit of %d", e.where, p.count, MAX_LINES)
            p.count = nil
          end
          problems[#problems + 1] = p
        end
      end
    end
  end

  -- The environment, read at most once per variable in one load, so a warning about an
  -- empty variable is said once and the bootstrap below cannot double it.
  local env_cache = {}
  local function envget(name)
    local hit = env_cache[name]
    if hit == nil then
      hit = {}
      if env_on then
        local ok, v = pcall(ports.env.get, name)
        if not ok then
          warnings[#warnings + 1] = string.format("reading the variable %s raised, so it was skipped", name)
        elseif v == nil then
          hit.value = nil
        elseif type(v) ~= "string" then
          warnings[#warnings + 1] = string.format("the variable %s did not come back as text, so it was skipped", name)
        elseif v == "" then
          warnings[#warnings + 1] = string.format("%s was set but empty; ignored", name)
        else
          hit.value = v
        end
      end
      env_cache[name] = hit
    end
    return hit.value
  end

  -- A profile section may not set a profile, whether or not it is the one selected.
  -- Otherwise selecting a profile could select another profile, and a file could be
  -- written that never settles.
  for i = 1, #files do
    local f = files[i]
    for pname, list in pairs(f.tree.profiles) do
      for j = 1, #list do
        if list[j].key == "profile" then
          problems[#problems + 1] = problem("not_allowed",
            "a profile section cannot select a profile", list[j].line,
            { layer = "profile:" .. pname .. "@" .. f.where, setting = "profile" })
        end
      end
    end
  end

  -- The bootstrap. The profile has to be chosen before the profile layers can exist, so
  -- it is resolved first, from -- highest first -- opts.profile, the environment, and
  -- the profile key in each file's base section, last file winning.
  local chosen, declared = nil, {}
  do
    local seen_name = {}
    for i = 1, #files do
      local names = declared_in(files[i].tree)
      for j = 1, #names do
        if not seen_name[names[j]] then
          seen_name[names[j]] = true
          declared[#declared + 1] = names[j]
        end
      end
    end
    table.sort(declared)

    -- `opts.profile` is applied as a value of the profile setting in the override layer,
    -- so a profile written straight into `opts.override` is the same statement made
    -- another way, and it has to choose the profile too. Otherwise `explain` would name
    -- the override as the layer that chose a profile that was never selected, and a
    -- typo there would run the defaults in silence -- the bug this module is against.
    local ps = schema.by_name.profile
    local forced = opts.profile
    if forced == nil and opts.override ~= nil then forced = opts.override.profile end
    if forced ~= nil then
      chosen = forced
    elseif ps then
      if env_on then
        for j = 1, #ps.env do
          local v = envget(ps.env[j])
          if v ~= nil then chosen = v; break end
        end
      end
      if chosen == nil then
        for i = 1, #files do
          local base = files[i].tree.base
          for j = 1, #base do
            if base[j].key == "profile" and trim(base[j].raw) ~= "" then chosen = base[j].raw end
          end
        end
      end
    end
    if chosen ~= nil and trim(chosen) == "" then chosen = nil end
  end

  if chosen ~= nil then
    local found = false
    for i = 1, #declared do
      if declared[i] == chosen then found = true; break end
    end
    if not found then
      local said = #declared > 0 and table.concat(declared, ", ") or "none"
      problems[#problems + 1] = problem("no_such_profile",
        string.format("no file declares the profile %s; the profiles declared are: %s", chosen, said),
        nil, { setting = "profile" })
    end
  end

  -- ---- the layers, lowest priority first, and this order is the contract ----

  local layers = {}
  local function layer(name, where)
    local l = { name = name, where = where or "", n = 0, contrib = {}, secrets = {} }
    layers[#layers + 1] = l
    return l
  end

  local builtin = layer("builtin", "")
  for i = 1, #schema.settings do
    local s = schema.settings[i]
    if s.default ~= nil then
      builtin.contrib[s.name] = { value = copy_value(s.default), raw = nil, where = "" }
    end
  end

  local function apply_entries(l, list)
    for i = 1, #list do
      local e = list[i]
      local s = schema.by_name[e.key]
      local mark = { layer = l.name, setting = e.key }
      if not s then
        local near = closest(e.key, schema.names)
        problems[#problems + 1] = problem("unknown_setting",
          string.format("%s is not a setting%s", e.key,
            near and (" -- did you mean " .. near .. "?") or ""), e.line, mark)
      elseif s.secret then
        problems[#problems + 1] = problem("not_allowed",
          string.format("%s is a secret and cannot be set in a configuration file; set %s instead",
            s.name, table.concat(s.env, " or ")), e.line, mark)
      elseif not s.file then
        problems[#problems + 1] = problem("not_allowed",
          string.format("%s cannot be set in a configuration file", s.name), e.line, mark)
      else
        local v, wanted = coerce(s, e.raw, e.quoted)
        if wanted then
          problems[#problems + 1] = problem("wrong_type",
            string.format("%s wants %s; got \"%s\"", s.name, wanted, e.raw), e.line, mark)
        else
          local bad = out_of_range(s, v)
          if bad then
            problems[#problems + 1] = problem("out_of_range",
              string.format("%s is %s, and it wants %s", s.name, valuetext(v), bad), e.line, mark)
          else
            l.contrib[s.name] = { value = v, raw = e.raw, where = "line " .. e.line }
          end
        end
      end
    end
  end

  for i = 1, #files do
    local f = files[i]
    apply_entries(layer("file:" .. f.where, f.where), f.tree.base)
    if chosen ~= nil and f.tree.profiles[chosen] then
      apply_entries(layer("profile:" .. chosen .. "@" .. f.where, f.where), f.tree.profiles[chosen])
    end
  end

  if env_on then
    local l = layer("env", "")
    for i = 1, #schema.settings do
      local s = schema.settings[i]
      if #s.env > 0 then
        local won, others = nil, {}
        for j = 1, #s.env do
          local v = envget(s.env[j])
          if v ~= nil then
            if won == nil then won = { name = s.env[j], value = v }
            else others[#others + 1] = s.env[j] end
          end
        end
        if won then
          if s.secret then
            l.secrets[s.name] = { value = won.value, where = won.name, others = others }
          else
            local mark = { layer = "env", setting = s.name, where = won.name }
            local v, wanted = coerce(s, won.value, false)
            if wanted then
              problems[#problems + 1] = problem("wrong_type",
                string.format("%s wants %s; the variable %s holds \"%s\"",
                  s.name, wanted, won.name, won.value), nil, mark)
            else
              local bad = out_of_range(s, v)
              if bad then
                problems[#problems + 1] = problem("out_of_range",
                  string.format("%s is %s in the variable %s, and it wants %s",
                    s.name, valuetext(v), won.name, bad), nil, mark)
              else
                l.contrib[s.name] = { value = v, raw = won.value, where = won.name }
              end
            end
          end
        end
      end
    end

    -- The typo scan. A variable that does nothing at all, silently, forever, is the
    -- reason it exists. A missing capability degrades to a stated gap, never a silent
    -- one and never a failure.
    if prefix == "" then
      warnings[#warnings + 1] = "the environment was not scanned for misspelt variables, because no prefix was given"
    elseif type(ports.env.names) ~= "function" then
      warnings[#warnings + 1] = "the environment was not scanned for misspelt variables, because the port does not list names"
    else
      local ok, list = pcall(ports.env.names)
      if not ok or type(list) ~= "table" then
        warnings[#warnings + 1] = "the environment could not be listed, so it was not scanned for misspelt variables"
      else
        local known = {}
        for varname in pairs(schema.by_env) do known[#known + 1] = varname end
        table.sort(known)
        local flagged = {}
        for i = 1, #list do
          local varname = list[i]
          if type(varname) == "string" and not flagged[varname]
             and varname:sub(1, #prefix) == prefix and not schema.by_env[varname] then
            flagged[varname] = true
            local near = closest(varname, known)
            local owner = near and schema.by_env[near] or nil
            problems[#problems + 1] = problem("unknown_env",
              string.format("%s is set and no setting reads it%s", varname,
                owner and string.format(" -- did you mean %s, which sets %s?", near, owner.name) or ""),
              nil, { layer = "env", where = varname })
          end
        end
      end
    end
  end

  if opts.override ~= nil or opts.profile ~= nil then
    local l = layer("override", "")
    if opts.override ~= nil then
      for k, v in pairs(opts.override) do
        l.contrib[k] = { value = copy_value(v), raw = nil, where = "" }
      end
    end
    if opts.profile ~= nil then
      l.contrib.profile = { value = opts.profile, raw = nil, where = "" }
    end
  end

  -- ---- resolution: the highest layer that had a value wins, and the rest are named ----

  local values, shadow, secrets, secret_meta = {}, {}, {}, {}
  for i = 1, #schema.settings do
    local s = schema.settings[i]
    if s.secret then
      local found, shadowed = nil, {}
      for j = 1, #layers do
        local sec = layers[j].secrets[s.name]
        if sec then
          found = { layer = layers[j].name, at = j, where = sec.where, value = sec.value }
          for k = 1, #sec.others do
            shadowed[#shadowed + 1] = { layer = layers[j].name, where = sec.others[k] }
          end
        end
      end
      if found then secrets[s.name] = found.value end
      secret_meta[s.name] = {
        layer = found and found.layer or nil,
        at = found and found.at or nil,
        where = found and found.where or nil,
        shadowed = shadowed,
      }
    else
      local cands = {}
      for j = 1, #layers do
        local one = layers[j].contrib[s.name]
        if one then
          cands[#cands + 1] = { layer = layers[j].name, at = j, where = one.where,
                                raw = one.raw, value = one.value }
        end
      end
      local sh = {}
      for j = #cands - 1, 1, -1 do
        sh[#sh + 1] = { layer = cands[j].layer, where = cands[j].where, raw = cands[j].raw }
      end
      shadow[s.name] = sh
      if #cands > 0 then values[s.name] = cands[#cands] end
    end
  end

  for i = 1, #schema.settings do
    local s = schema.settings[i]
    if s.required then
      local have
      if s.secret then have = secrets[s.name] ~= nil else have = values[s.name] ~= nil end
      if not have then
        local help
        if #s.env > 0 then help = "set " .. table.concat(s.env, " or ")
        else help = "nothing supplied it and it has no default" end
        problems[#problems + 1] = problem("missing",
          string.format("no %s: %s", s.name, help), nil, { setting = s.name })
      end
    end
  end

  if #problems > 0 then return nil, problems end

  local public_layers = {}
  for i = 1, #layers do
    public_layers[i] = { name = layers[i].name, where = layers[i].where, n = 0 }
  end

  local st = {
    schema = schema,
    profile = chosen,
    layers = public_layers,
    warnings = warnings,
    values = values,
    shadow = shadow,
    secrets = secrets,
    secret_meta = secret_meta,
    profiles = declared,
  }
  tally(st)
  return finish(st)
end

-- ---------------------------------------------------------------------------
-- Reading a resolved config.

-- The value that won, already read back into the setting's kind. Returns the default
-- when no layer supplied one, and nil when there is no default either -- which is why
-- nil is a legitimate answer here and not an error.
function config.get(c, name)
  local st = state(c, "config.get")
  if type(name) ~= "string" then
    error("config.get: `name` is a setting name, got " .. type(name), 2)
  end
  local s = st.schema.by_name[name]
  if not s then
    local near = closest(name, st.schema.names)
    error("config.get: there is no setting called " .. name ..
      (near and (" -- did you mean " .. near .. "?") or ""), 2)
  end
  if s.secret then
    error("config.get: " .. name .. " is a secret; use config.secret to read a secret", 2)
  end
  local won = st.values[name]
  if won == nil then return nil end
  return copy_value(won.value)
end

-- The only way a credential leaves this module. It does not log, does not cache and
-- does not memoise; it reads the resolved store and nothing else.
function config.secret(c, name)
  local st = state(c, "config.secret")
  if type(name) ~= "string" then
    error("config.secret: `name` is a setting name, got " .. type(name), 2)
  end
  local s = st.schema.by_name[name]
  if not s then
    error("config.secret: there is no setting called " .. name, 2)
  end
  if not s.secret then
    error("config.secret: " .. name .. " is not a secret; use config.get", 2)
  end
  return st.secrets[name]
end

-- Why this value. The reason the module exists. Never raises for a secret: `explain` is
-- safe on every setting, which is what lets `report` be built out of it.
function config.explain(c, name)
  local st = state(c, "config.explain")
  if type(name) ~= "string" then
    error("config.explain: `name` is a setting name, got " .. type(name), 2)
  end
  local s = st.schema.by_name[name]
  if not s then
    local near = closest(name, st.schema.names)
    error("config.explain: there is no setting called " .. name ..
      (near and (" -- did you mean " .. near .. "?") or ""), 2)
  end

  if s.secret then
    local m = st.secret_meta[name] or { shadowed = {} }
    local shadowed = {}
    for i = 1, #m.shadowed do
      shadowed[i] = { layer = m.shadowed[i].layer, where = m.shadowed[i].where }
    end
    return {
      name = name, kind = s.kind, value = nil, raw = nil,
      layer = m.layer, where = m.where,
      secret = true, redacted = true, set = st.secrets[name] ~= nil,
      shadowed = shadowed,
    }
  end

  local won = st.values[name]
  local shadowed = {}
  local sh = st.shadow[name] or {}
  for i = 1, #sh do
    shadowed[i] = { layer = sh[i].layer, where = sh[i].where, raw = sh[i].raw }
  end
  -- Written out rather than folded into `and`/`or`: a boolean setting that resolved to
  -- false is set, and `x and false or nil` would report it as never supplied at all.
  local record = {
    name = name, kind = s.kind,
    value = nil, layer = nil, where = nil, raw = nil,
    secret = false, redacted = false, set = won ~= nil,
    shadowed = shadowed,
  }
  if won ~= nil then
    record.value = copy_value(won.value)
    record.layer = won.layer
    record.where = won.where
    record.raw = won.raw
  end
  return record
end

-- One line per setting, sorted by name, for a person. A secret is rendered as
-- (secret, set) or (secret, unset) and never as anything else -- not a prefix, not a
-- length, not a hash, not a run of asterisks whose count is the length. Whether a
-- credential is present is operationally necessary; how long it is, is not.
function config.report(c)
  local st = state(c, "config.report")
  local rows = {}
  local wide_name, wide_value = 0, 0
  for i = 1, #st.schema.settings do
    local s = st.schema.settings[i]
    local shown, source
    if s.secret then
      local m = st.secret_meta[s.name] or {}
      shown = st.secrets[s.name] ~= nil and "(secret, set)" or "(secret, unset)"
      source = m.layer and (m.where ~= "" and m.where ~= nil
        and (m.layer .. " " .. m.where) or m.layer) or "-"
    else
      local won = st.values[s.name]
      if won == nil then
        shown, source = "(unset)", "-"
      else
        shown = valuetext(won.value)
        source = (won.where ~= nil and won.where ~= "") and (won.layer .. " " .. won.where) or won.layer
      end
    end
    rows[#rows + 1] = { name = s.name, shown = shown, source = source }
    if #s.name > wide_name then wide_name = #s.name end
    if #shown > wide_value then wide_value = #shown end
  end
  local lines = {}
  for i = 1, #rows do
    lines[i] = string.format("%-" .. (wide_name + 2) .. "s%-" .. (wide_value + 2) .. "s%s",
      rows[i].name, rows[i].shown, rows[i].source)
  end
  return lines
end

-- Every non-secret setting as a fresh plain table, safe to serialise, log, put in a
-- session file or hand to a subprocess. A secret setting is absent, not present and
-- nil, so a caller iterating the table cannot find a key it might try to fill.
function config.public(c)
  local st = state(c, "config.public")
  local out = {}
  for i = 1, #st.schema.settings do
    local s = st.schema.settings[i]
    if not s.secret then
      local won = st.values[s.name]
      if won ~= nil then out[s.name] = copy_value(won.value) end
    end
  end
  return out
end

-- The profile names the files declared, sorted, as a fresh list.
function config.profiles(c)
  local st = state(c, "config.profiles")
  return list_of(st.profiles)
end

-- ---------------------------------------------------------------------------
-- config.redact
--
-- A comparison against the configured secrets, not a search for anything that looks
-- like a credential. Plain text matching, never a pattern: a credential holding a
-- percent sign or a dash must not become a Lua pattern.

local REDACTED = "[redacted]"
local MAX_DEPTH = 16

local function scrub_string(s, needles)
  for i = 1, #needles do
    local needle = needles[i]
    local at, parts = 1, nil
    while true do
      local from, to = s:find(needle, at, true)
      if not from then break end
      parts = parts or {}
      parts[#parts + 1] = s:sub(at, from - 1)
      parts[#parts + 1] = REDACTED
      at = to + 1
    end
    if parts then
      parts[#parts + 1] = s:sub(at)
      s = table.concat(parts)
    end
  end
  return s
end

local function scrub(v, needles, depth, memo)
  local t = type(v)
  if t == "string" then return scrub_string(v, needles) end
  if t == "function" then return "<function>" end
  if t == "userdata" then return "<userdata>" end
  if t == "thread" then return "<thread>" end
  if t ~= "table" then return v end
  if memo[v] then return memo[v] end
  if depth > MAX_DEPTH then return "<deep>" end
  local out = {}
  memo[v] = out
  for k, item in pairs(v) do
    local key = k
    if type(k) == "string" then key = scrub_string(k, needles) end
    out[key] = scrub(item, needles, depth + 1, memo)
  end
  return out
end

function config.redact(c, v)
  local st = state(c, "config.redact")
  local needles = {}
  for _, value in pairs(st.secrets) do
    if type(value) == "string" and value ~= "" then needles[#needles + 1] = value end
  end
  if #needles == 0 then
    if type(v) == "table" then return scrub(v, needles, 1, {}) end
    return v
  end
  return scrub(v, needles, 1, {})
end

-- ---------------------------------------------------------------------------
-- config.with -- a derived config with one more explicit layer on top.

function config.with(c, override)
  local st = state(c, "config.with")
  check_override("config.with", st.schema, override)

  local n = 2
  for i = 1, #st.layers do
    local d = st.layers[i].name:match("^override:(%d+)$")
    if d and tonumber(d) >= n then n = tonumber(d) + 1 end
  end
  local name = "override:" .. n

  local at = #st.layers + 1                 -- the position the new layer will take
  local values, shadow = {}, {}
  for k, won in pairs(st.values) do
    values[k] = { value = copy_value(won.value), layer = won.layer, at = won.at,
                  where = won.where, raw = won.raw }
  end
  for k, list in pairs(st.shadow) do
    local sh = {}
    for i = 1, #list do sh[i] = { layer = list[i].layer, where = list[i].where, raw = list[i].raw } end
    shadow[k] = sh
  end
  for k, v in pairs(override) do
    local was = values[k]
    if was then
      if shadow[k] == nil then shadow[k] = {} end
      table.insert(shadow[k], 1, { layer = was.layer, where = was.where, raw = was.raw })
    end
    values[k] = { value = copy_value(v), layer = name, at = at, where = "", raw = nil }
  end

  local secrets, secret_meta = {}, {}
  for k, value in pairs(st.secrets) do secrets[k] = value end
  for k, m in pairs(st.secret_meta) do
    local sh = {}
    for i = 1, #m.shadowed do sh[i] = { layer = m.shadowed[i].layer, where = m.shadowed[i].where } end
    secret_meta[k] = { layer = m.layer, at = m.at, where = m.where, shadowed = sh }
  end

  local layers = {}
  for i = 1, #st.layers do
    layers[i] = { name = st.layers[i].name, where = st.layers[i].where, n = 0 }
  end
  layers[#layers + 1] = { name = name, where = "", n = 0 }

  local warnings = list_of(st.warnings)

  local derived = {
    schema = st.schema,
    profile = st.profile,
    layers = layers,
    warnings = warnings,
    values = values,
    shadow = shadow,
    secrets = secrets,
    secret_meta = secret_meta,
    profiles = list_of(st.profiles),
  }
  tally(derived)
  return finish(derived)
end

return config
