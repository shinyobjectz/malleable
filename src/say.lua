-- say -- a declaration rendered as the Background that would declare it, and what it
-- could not say.
--
-- The is vocabulary compiles a feature's Background to the table `agent.*` builds
-- (src/declare.lua). This is the other direction: from the table, the lines. For an agent
-- written in a feature it is the identity, up to order and spelling; for one written in
-- Lua it is what the wall can score and what a person can read, and the list of what
-- stayed in the Lua -- a hook, a body, a beat that runs a function -- is the UNSAID.
--
-- Two uses (docs/spec/say.md): `--say` prints it; `--conforms` renders a program and a
-- contract and reports the lines only one of them says, in the vocabulary's own words.
--
-- Requires `spec` for the argument types and nothing else. Reads the table, runs nothing.

local say = {}

local function q(s) return string.format("%q", tostring(s)):gsub("\\\n", "\\n") end
local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The default budget `spec.new` gives, said out loud rather than left implicit: a
-- rendering that hid the default would hide a fact a reviewer asks about first.
local DEFAULT_BUDGET = 24

local KIND_WORD = { string = "string", number = "number", boolean = "boolean", object = "table", array = "list" }

local function type_word(p)
  local t
  if p.choices then t = "one of " .. table.concat(p.choices, ", ") else t = KIND_WORD[p.kind] or p.kind end
  if p.required == false then t = "optional " .. t end
  return t
end

-- One rendered line: the text, and under it a doc string or a table. `blocks` is what
-- `--conforms` compares, so a body's text is part of the line that declares it.
local function block(text, doc, fence, rows)
  return { text = text, doc = doc, fence = fence, rows = rows }
end

local function rows_of(header, list)
  local out = { header }
  for i = 1, #list do out[#out + 1] = list[i] end
  return out
end

-- The lines, in the order the vocabulary lists them: who it is, what it can reach, its
-- tools, what it keeps, its beats, its steps, its policy.
local function lines_of(a)
  local out, unsaid = {}, {}
  local function line(text, doc, fence, rows) out[#out + 1] = block(text, doc, fence, rows) end
  local function cannot(fmt, ...) unsaid[#unsaid + 1] = string.format(fmt, ...) end
  local kits = a.kits or {}
  local from_kit, store_from_kit = {}, {}
  for _, k in pairs(kits) do
    for name in pairs(type(k) == "table" and k.tools or {}) do from_kit[name] = k end
    for name in pairs(type(k) == "table" and k.stores or {}) do store_from_kit[name] = k end
  end

  -- who it is
  if a.name then line("the agent is called " .. a.name) end
  if a.model then line("its model is " .. q(a.model)) end
  if a.reasoning then line("its reasoning is " .. a.reasoning) end
  line(string.format("it may take %d step%s", a.budget or DEFAULT_BUDGET, (a.budget or DEFAULT_BUDGET) == 1 and "" or "s"))
  if a.system then line("it is briefed:", a.system) end
  if a.trust then line("its trust is " .. a.trust) end

  -- what it can reach
  if kits.files then
    line(kits.files.read_only and "it reads the workspace" or "it reads and writes the workspace")
    for _, g in ipairs(kits.files.deny or {}) do line("it never touches " .. q(g)) end
  end
  if kits.shell then
    line("it runs commands")
    local ms = kits.shell.timeout_ms
    if ms then
      if ms % 1000 == 0 then
        line(string.format("each command may run %d second%s", ms / 1000, ms == 1000 and "" or "s"))
      else
        cannot("the shell's timeout is %d ms, and the vocabulary counts whole seconds", ms)
      end
    end
  end
  if kits.plan then line("it keeps a plan") end
  if kits.history then line("it can read its history") end
  if kits.authoring then line("it edits agents in " .. q(kits.authoring.folder or "")) end

  -- the workspace's own kits (docs/spec/kit.md): the file lines, then each kit's lines as
  -- the feature said them, or as the kit says them back, or one unsaid sentence
  for _, path in ipairs(a.kit_files or {}) do line("it uses the kit " .. q(path)) end
  local own = {}
  for name, k in pairs(kits) do
    if type(k) == "table" and k.kit then own[#own + 1] = name end
  end
  table.sort(own)
  for _, name in ipairs(own) do
    local k = kits[name]
    if k.lines then
      for _, text in ipairs(k.lines) do line(text) end
    elseif type(k.kit.says) == "function" then
      for _, text in ipairs(k.kit.says(k.told or {}) or {}) do line(text) end
    else
      cannot("the kit %s was used from Lua and does not say itself back (no `says`)", name)
    end
  end

  -- what it keeps: stores before the tools that write them, as the vocabulary orders it
  for _, name in ipairs(a.store_order or {}) do
    local st = a.stores[name]
    if store_from_kit[name] then st = nil end     -- a kit's store is said by the kit's line
    local rows = {}
    if st then
    for _, col in ipairs(st.column_order) do
      rows[#rows + 1] = { col, type_word(st.columns[col]), st.columns[col].description or "" }
    end
    line("it keeps a store " .. name .. " of " .. q(st.about) .. ":", nil, nil, rows_of({ "column", "type", "about" }, rows))
    for _, col in ipairs(st.sort or {}) do line("the store " .. name .. " is sorted by " .. col) end
    end
  end

  -- its tools
  local limits = kits.limits or {}
  for _, name in ipairs(a.order or {}) do
    local t = a.tools[name]
    local kit = from_kit[name]
    if kit then
      -- a kit's tool is said by the kit's line; only what the file changed about it is a line
      local was = kit.tools[name]
      if t.about ~= was.about then line("the tool " .. name .. " is for " .. q(t.about)) end
      if t.ask and not was.ask then line("the tool " .. name .. " asks first") end
    elseif kits.delegates and kits.delegates[name] then
      line("it hands work to the agent in " .. q(kits.delegates[name].path) .. " as " .. name)
    elseif t.agents then
      cannot("the tool %s hands work to an agent declared in Lua, which no line names", name)
    else
      if #t.arg_order == 0 then
        line("it has a tool " .. name .. " for " .. q(t.about))
      else
        local rows = {}
        for _, k in ipairs(t.arg_order) do
          rows[#rows + 1] = { k, type_word(t.args[k]), t.args[k].description or "" }
        end
        line("it has a tool " .. name .. " for " .. q(t.about) .. ", which takes:", nil, nil,
             rows_of({ "argument", "type", "about" }, rows))
      end
      if t.ask then
        if t.edit and #t.edit > 0 then
          for _, arg in ipairs(t.edit) do
            line("the tool " .. name .. " asks first, letting the person change " .. arg)
          end
        else
          line("the tool " .. name .. " asks first")
        end
      end
      local b = t.said
      if b == nil then
        cannot("the body of %s is Lua in the program, not a doc string", name)
      elseif b.kind == "lua" then line("the tool " .. name .. " does:", b.doc, "lua")
      elseif b.kind == "answers" then line("the tool " .. name .. " answers " .. q(b.text))
      elseif b.kind == "adds" then line("the tool " .. name .. " adds a row to " .. b.store)
      elseif b.kind == "lists" then line("the tool " .. name .. " lists " .. b.store)
      end
    end
    if t.preview then line("the tool " .. name .. " shows its call before it runs") end
    for _, r in ipairs(t.requires or {}) do
      if r.source then
        line("the tool " .. name .. " requires " .. q(r.says) .. ", checked by:", r.source, "lua")
      else
        cannot("the requirement %s of %s is checked by Lua in the program", q(r.says), name)
      end
    end
    if limits[name] then
      line(string.format("the tool %s may be called at most %d time%s", name, limits[name], limits[name] == 1 and "" or "s"))
    end
    if t.ends then cannot("the tool %s ends a run (`ends = true`), which no line says", name) end
  end

  -- servers
  for _, name in ipairs(a.server_order or {}) do
    local sv = a.servers[name]
    local cfg = sv.config or {}
    local keys = {}
    for k in pairs(cfg) do keys[#keys + 1] = k end
    table.sort(keys)
    local rows = {}
    for _, k in ipairs(keys) do
      local v = cfg[k]
      if k == "tools" and type(v) == "table" then v = table.concat(v, ", ") end
      if type(v) == "table" or type(v) == "function" then
        cannot("the server %s's %s is a %s, which a table cell cannot hold", name, k, type(v))
      else
        rows[#rows + 1] = { k, tostring(v) }
      end
    end
    line("it uses the server " .. name .. " with:", nil, nil, rows_of({ "key", "value" }, rows))
  end

  -- skills
  for _, name in ipairs(a.skill_order or {}) do
    local sk = a.skills[name]
    if sk.file then
      line("it keeps a skill " .. name .. " for " .. q(sk.about) .. ", in " .. q(sk.file))
    else
      line("it keeps a skill " .. name .. " for " .. q(sk.about) .. ":", sk.does)
    end
  end

  -- beats
  for _, name in ipairs(a.beat_order or {}) do
    local b = a.beats[name]
    if type(b.runs) ~= "string" then
      cannot("the beat %s runs a function, and a line asks with a prompt", name)
    elseif b.every then
      line(string.format("the beat %s comes every %d second%s and asks %s", name, b.every, b.every == 1 and "" or "s", q(b.runs)))
    else
      line(string.format("the beat %s comes every day at %s and asks %s", name, q(b.day_at), q(b.runs)))
    end
    if b.once_per then line("the beat " .. name .. " runs once per " .. b.once_per) end
    for _, k in ipairs { "tz", "grace", "about" } do
      if b[k] ~= nil then cannot("the beat %s has `%s`, which no line says", name, k) end
    end
  end

  -- its own steps
  for _, expr in ipairs(a.step_order or {}) do
    local st = a.steps[expr]
    if st.kit then
      -- a kit's step is said by the kit's line
    elseif st.source then
      line("the step " .. q(expr) .. (st.phase == "given" and " sets up:" or " checks:"), st.source, "lua")
    else
      cannot("the step %s has a Lua body in the program", q(expr))
    end
  end

  -- policy
  for _, e in ipairs(a.policy or {}) do
    local extra = false
    for k in pairs(e) do if k ~= "tool" and k ~= "allow" and k ~= "deny" then extra = true end end
    if extra or type(e.tool) ~= "string" then
      cannot("a policy entry with more than a tool name (`when`, `reason`) has no line")
    elseif e.allow then line("it may always call " .. e.tool)
    else line("it may never call " .. e.tool) end
  end

  -- hooks: the two a limit installs are said by the limit line; any other is a hook
  local hooked = 0
  for _, list in pairs(a.hooks or {}) do hooked = hooked + #list end
  local from_limits = 0
  for _ in pairs(limits) do from_limits = from_limits + 2 end
  if hooked > from_limits then
    cannot("%d hook%s (agent.on) watch the run, and a hook is not sayable", hooked - from_limits,
           hooked - from_limits == 1 and "" or "s")
  end

  return out, unsaid
end

local function render_block(b, keyword, indent)
  local out = { indent .. keyword .. " " .. b.text }
  if b.doc ~= nil then
    out[#out + 1] = indent .. '  """' .. (b.fence or "")
    for l in (tostring(b.doc) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = indent .. "  " .. l end
    -- a doc string that ends without a newline is rendered the same as one that does
    if out[#out] == indent .. "  " then out[#out] = nil end
    out[#out + 1] = indent .. '  """'
  end
  if b.rows then
    local widths = {}
    for _, row in ipairs(b.rows) do
      for i, cell in ipairs(row) do widths[i] = math.max(widths[i] or 0, #tostring(cell)) end
    end
    for _, row in ipairs(b.rows) do
      local cells = {}
      for i, cell in ipairs(row) do
        cells[i] = tostring(cell) .. string.rep(" ", widths[i] - #tostring(cell))
      end
      out[#out + 1] = indent .. "  | " .. table.concat(cells, " | ") .. " |"
    end
  end
  return table.concat(out, "\n")
end

--- The declaration `a` as the text of a feature: a Feature line, a Background of is lines,
--- and after it one `#` line for each thing the vocabulary could not say. Answers the text
--- and the list of unsaid sentences.
function say.render(a, opts)
  opts = opts or {}
  local lines, unsaid = lines_of(a)
  local out = { "Feature: " .. tostring(a.name or "agent"), "", "  Background:" }
  for i = 1, #lines do
    out[#out + 1] = render_block(lines[i], i == 1 and "Given" or "And", "    ")
  end
  if #unsaid > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "  # unsaid, and kept in the program:"
    for i = 1, #unsaid do out[#out + 1] = "  #   " .. unsaid[i] end
  end
  return table.concat(out, "\n") .. "\n", unsaid
end

--- The is lines of `a`, each as one string with its doc string or table folded in, so two
--- declarations compare line for line.
function say.lines(a)
  local lines, unsaid = lines_of(a)
  local out = {}
  for i = 1, #lines do out[i] = trim(render_block(lines[i], "", "")) end
  return out, unsaid
end

--- What `program` says that `contract` does not, and the other way round, in the
--- vocabulary's words. Answers `{ ok, only_program, only_contract, unsaid_program,
--- unsaid_contract }`; `ok` is true when every sayable line is on both sides.
function say.conforms(program, contract)
  local p, up = say.lines(program)
  local c, uc = say.lines(contract)
  local in_p, in_c = {}, {}
  for _, l in ipairs(p) do in_p[l] = true end
  for _, l in ipairs(c) do in_c[l] = true end
  local only_p, only_c = {}, {}
  for _, l in ipairs(p) do if not in_c[l] then only_p[#only_p + 1] = l end end
  for _, l in ipairs(c) do if not in_p[l] then only_c[#only_c + 1] = l end end
  return { ok = #only_p == 0 and #only_c == 0, only_program = only_p, only_contract = only_c,
           unsaid_program = up, unsaid_contract = uc }
end

--- A conformance report as sentences. `names` is `{ program = "a.lua", contract = "a.feature" }`.
function say.report(r, names)
  names = names or {}
  local pn, cn = names.program or "the program", names.contract or "the contract"
  local out = {}
  for _, l in ipairs(r.only_program) do
    out[#out + 1] = string.format("%s says `%s`, and %s does not", pn, (l:gsub("\n.*", " ...")), cn)
  end
  for _, l in ipairs(r.only_contract) do
    out[#out + 1] = string.format("%s says `%s`, and %s does not", cn, (l:gsub("\n.*", " ...")), pn)
  end
  for _, u in ipairs(r.unsaid_program) do
    out[#out + 1] = string.format("%s keeps something no line says: %s", pn, u)
  end
  for _, u in ipairs(r.unsaid_contract) do
    out[#out + 1] = string.format("%s keeps something no line says: %s", cn, u)
  end
  if #out == 0 then out[1] = pn .. " and " .. cn .. " say the same agent" end
  return table.concat(out, "\n") .. "\n"
end

return say
