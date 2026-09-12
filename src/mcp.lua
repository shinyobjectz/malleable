-- mcp -- tools that live in another process.
--
-- A server tool is made the same kind of thing as a local one before the model sees it:
-- by the time `agent.schema` is read, nothing tells which were declared and which fetched.
--
-- A declaration NAMES a server:
--
--     agent.uses "github" {
--       command = { "npx", "-y", "@modelcontextprotocol/server-github" },
--       tools   = { "list_issues", "create_issue" },   -- everything, if absent
--       ask     = true,
--     }
--
-- and nothing reaches for it (rule 2). `mcp.connect` asks at run time through the `mcp`
-- port, which owes
--
--     list(server, config) -> { descriptor, ... } | nil, err
--     call(server, tool, args) -> text | result | nil, err
--
-- and knows what a transport is so that this module does not. Everything else the
-- declaration states -- a command line, a URL, headers -- is passed to the port
-- untouched, neither read nor validated here.
--
-- A descriptor is either in the harness's shape (`args`) or carries the JSON Schema a
-- server sends (`input_schema` / `inputSchema`), which `mcp.params` converts.

local spec = require "spec"

local mcp = {}

local function fail(fmt, ...)
  error("agent: " .. string.format(fmt, ...), 3)
end

-- JSON Schema, as far as a tool signature needs it. Anything richer -- oneOf, nested
-- objects, enums -- becomes the nearest of the five kinds and keeps its description,
-- because a tool argument the model can still fill imperfectly beats a tool that could
-- not be offered at all. What is NOT done here is inventing a constraint the server
-- did not state: an unknown type becomes a string with the schema's own words.
local KINDS = {
  string = "string", number = "number", integer = "number",
  boolean = "boolean", object = "table", array = "list",
}

function mcp.params(schema)
  local args = {}
  if type(schema) ~= "table" then return args end
  local props = schema.properties
  if type(props) ~= "table" then return args end
  local required = {}
  if type(schema.required) == "table" then
    for i = 1, #schema.required do required[schema.required[i]] = true end
  end
  for k, v in pairs(props) do
    if type(k) == "string" then
      local t = type(v) == "table" and v.type or nil
      if type(t) == "table" then t = t[1] end                 -- ["string","null"]
      local kind = KINDS[t] or "string"
      local why = (type(v) == "table" and type(v.description) == "string") and v.description or ""
      local maker = spec.types[required[k] and kind or (kind .. "_opt")]
      args[k] = maker(why)
    end
  end
  return args
end

-- What the model will call this tool. A server's tool name is unique on that server
-- and nowhere else, so two servers offering `search` must not collide silently into
-- one -- and the collision would be silent, because `spec.add_tool` would refuse the
-- second and the run would simply be missing a tool.
function mcp.tool_name(server, tool)
  return server.name .. (server.join or "_") .. tool
end

local function text_of(v)
  if type(v) == "string" then return v end
  if type(v) == "table" then
    -- The content-list shape a server answers with. Text parts, in order; anything
    -- else is named rather than dropped, so an image does not read as an empty reply.
    if type(v.content) == "table" then
      local parts = {}
      for i = 1, #v.content do
        local c = v.content[i]
        if type(c) == "table" then
          if type(c.text) == "string" then parts[#parts + 1] = c.text
          elseif type(c.type) == "string" then parts[#parts + 1] = "[" .. c.type .. "]" end
        elseif type(c) == "string" then parts[#parts + 1] = c end
      end
      if #parts > 0 then return table.concat(parts, "\n") end
    end
    if type(v.text) == "string" then return v.text end
  end
  return tostring(v)
end

-- Ask every declared server what it has, and add what it answers as tools.
--
-- Returns `added, problems` -- both lists of strings, both always tables. A server that is
-- down, or answers unreadably, is a PROBLEM and not an error: the run continues with the
-- tools it does have. A name collision is not tolerated and is reported per tool.
--
-- Idempotent. `a.connected[name]` records what has been asked already, so a host that
-- calls this on every run does not re-add on the second.
function mcp.connect(a, p, opts)
  opts = opts or {}
  if type(a) ~= "table" then fail("mcp.connect takes a declaration table") end
  local added, problems = {}, {}
  if #a.server_order == 0 then return added, problems end

  local port = p and p.mcp
  if type(port) ~= "table" or type(port.list) ~= "function" or type(port.call) ~= "function" then
    for i = 1, #a.server_order do
      problems[#problems + 1] = ("the server %q was declared, and this run has no mcp port to reach it with"):format(a.server_order[i])
    end
    return added, problems
  end

  -- Optionally watched. `opts.watch(name)` is called as each server is reached and
  -- answers a function to call when it has been, with whether it answered and how many
  -- tools came back. Two scalars, and nothing else can travel: this is how `agent.run`
  -- puts a `malleable.server` span around a connection without this module holding a
  -- recorder, reading a clock, or being able to write a span attribute at all. A
  -- callback that could carry a string would be a payload leak with extra steps.
  local watch = type(opts.watch) == "function" and opts.watch or nil
  local function watching(name)
    if not watch then return function () end end
    local ok, finish = pcall(watch, name)
    if ok and type(finish) == "function" then
      return function (reached, tools) pcall(finish, reached, tools) end
    end
    return function () end
  end

  a.connected = a.connected or {}
  for i = 1, #a.server_order do
    local server = a.servers[a.server_order[i]]
    if not a.connected[server.name] then
      local done = watching(server.name)
      local before = #added
      local listed, err = port.list(server.name, server.config)
      if type(listed) ~= "table" then
        done(false, 0)
        problems[#problems + 1] = ("the server %q did not answer with its tools: %s"):format(
          server.name, type(err) == "table" and (err.message or err.code) or tostring(err))
      else
        local want = nil
        if server.tools then
          want = {}
          for j = 1, #server.tools do want[server.tools[j]] = true end
        end
        local seen = {}
        for j = 1, #listed do
          local d = listed[j]
          if type(d) ~= "table" or type(d.name) ~= "string" or d.name == "" then
            problems[#problems + 1] = ("the server %q offered a tool with no name"):format(server.name)
          elseif want and not want[d.name] then
            -- Not a problem: the declaration said which tools to take, and this is
            -- the declaration being obeyed.
          else
            seen[d.name] = true
            local local_name = mcp.tool_name(server, d.name)
            local args = type(d.args) == "table" and d.args
                      or mcp.params(d.input_schema or d.inputSchema)
            local about = type(d.about) == "string" and d.about
                       or (type(d.description) == "string" and d.description)
                       or ("the " .. d.name .. " tool on " .. server.name)
            local ask = server.ask
            if ask == nil then ask = true end   -- rule 4: another process is not this one
            local ok, why = pcall(spec.add_tool, a, local_name, {
              about = about,
              args  = args,
              ask   = ask,
              run   = function (c)
                local out, cerr = port.call(server.name, d.name, c.args)
                if out == nil then
                  return ("%s could not run %s: %s"):format(server.name, d.name,
                    type(cerr) == "table" and (cerr.message or cerr.code) or tostring(cerr))
                end
                return text_of(out)
              end,
            })
            if ok then added[#added + 1] = local_name
            else problems[#problems + 1] = tostring(why) end
          end
        end
        if want then
          local missing = {}
          for _, wanted in ipairs(server.tools) do
            if not seen[wanted] then missing[#missing + 1] = wanted end
          end
          if #missing > 0 then
            -- Named loudly. A declaration that asks for a tool the server does not
            -- have is a typo or a version drift, and both read at run time as an agent
            -- that quietly cannot do the thing it was written to do.
            problems[#problems + 1] = ("the server %q does not offer: %s"):format(
              server.name, table.concat(missing, ", "))
          end
        end
        a.connected[server.name] = true
        done(true, #added - before)
      end
    end
  end
  table.sort(added)
  return added, problems
end

return mcp
