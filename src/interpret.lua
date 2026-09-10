-- interpret — the surface a workspace extends the interpretive layer through.
--
-- Canon: docs/PAGES.md "The four layers"; the rule kinds are mar-9cja, the refusals are
-- mar-i182 under mar-4o07. Rendered into `.work/rules/rules.lua` and read back by
-- canvas/rules.rs; the shapes here are ta_agent::spec::Rule's, field for field.
--
-- `agent` declares behaviour. `interpret` declares reading. One prefix each.
--
-- THE DESIGN CONSTRAINT, and the reason the surface is shaped as it is: there is no field
-- anywhere below that can hold a regex. A mark is assembled from parts, the one part that
-- takes free text is escaped before it reaches a matcher, and every shape is a constant
-- held by identity rather than a string. A reading of ordinary language cannot be written
-- here at all: it belongs to the map, and `interpret.means` is where it goes.

local interpret = {}

local function fail(fmt, ...)
  error(string.format(fmt, ...), 3)
end

-- ---------------------------------------------------------------- the closed vocabularies
--
-- Every one of these is a table held by IDENTITY, never a string. A string field would let
-- an author write `shape = "[A-Za-z ]+"` and have it quietly work; a table cannot carry a
-- payload. A misspelling yields nil, and nil is refused at access (see the metatable at the
-- bottom of this file) rather than being mistaken for an omitted field.

local function const(tag, name, extra)
  local t = { [tag] = true, name = name }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

-- Each shape carries TWO renderings, and the distinction is not cosmetic: `pattern` is a
-- Lua pattern, used here and by gate two to match text in this process; `rust` is a Rust
-- regex, which is what the store's `pattern` field is compiled as by the harness. Emitting
-- the Lua form into the store would fail SILENTLY - `%$tired` as a Rust regex is a literal
-- percent, an end-of-line anchor and then "tired", which matches nothing at all.
interpret.SHOUTED = const("__shape", "SHOUTED", { pattern = "%u[%u%d_]*", rust = "[A-Z][A-Z0-9_]*", human = "an all-capitals word" })
interpret.WORD    = const("__shape", "WORD",    { pattern = "%a[%w_%-]*", rust = "[A-Za-z][A-Za-z0-9_-]*", human = "a word" })
interpret.NUMBER  = const("__shape", "NUMBER",  { pattern = "%d+",        rust = "\\d+", human = "a whole number" })
interpret.DATE    = const("__shape", "DATE",    { pattern = "%d%d%d%d%-%d%d%-%d%d", rust = "\\d{4}-\\d{2}-\\d{2}", human = "a date, written 2026-09-10" })

interpret.LINE_START = const("__at", "LINE_START")

-- What the map should read a mark as. The eight kinds the map already knows, narrowed to
-- the ones a workspace may mint: a mark cannot declare itself a machine or a definition,
-- because those are structure Build derives rather than notation a writer invents.
interpret.VALUE = const("__means", "value")
interpret.FLAG  = const("__means", "flag")
interpret.STEP  = const("__means", "step")

-- Whom a rule binds (ta_agent::spec AUDIENCES). Build sets this from the sentence when a
-- rule is derived; a hand-written declaration says it outright.
interpret.BUILD  = const("__binds", "build")
interpret.STORE  = const("__binds", "store")
interpret.MIDDLE = const("__binds", "middle")
interpret.HOST   = const("__binds", "host")
interpret.AGENT  = const("__binds", "agent")

-- Whether a checker can run it, or whether it is a way of thinking a briefing carries.
interpret.FUNCTIONAL  = const("__mode", "functional")
interpret.CONTEXTUAL  = const("__mode", "contextual")

local function tagged(v, tag)
  return type(v) == "table" and v[tag] == true
end

-- --------------------------------------------------------------------------- the guards

-- Every Lua and Rust pattern metacharacter, quoted. The `word` field is a literal and is
-- never compiled: this is what stops an author reaching the engine through the one field
-- that takes free text.
local function literal(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\/]", "%%%1"))
end

-- The same job for Rust's regex syntax, which is what the store's `pattern` is compiled as.
local function literal_rust(s)
  return (s:gsub("[%^%$%(%)%.%[%]%*%+%-%?{}|\\/]", "\\%1"))
end

local PATTERN_FIELDS = { "pattern", "regex", "match", "matches", "re", "glob", "expr", "rx" }

local function refuse_pattern_fields(t, what)
  for i = 1, #PATTERN_FIELDS do
    local k = PATTERN_FIELDS[i]
    if t[k] ~= nil then
      fail("%s: `%s` is not a field here and never will be. interpret accepts no pattern - assemble a "
        .. "mark from `lead`, `word` and `shape`, or use interpret.means for something the map can "
        .. "already see (mar-i182)", what, k)
    end
  end
end

-- A rule with no sentence is authored rather than derived, and the whole model is that a
-- workspace states its rules in prose. `is` is that sentence, and it is required
-- everywhere: a reading nobody can read back in English is a reading nobody can review.
local function check_is(t, what)
  if type(t.is) ~= "string" or t.is:match("^%s*$") then
    fail("%s needs `is`: the sentence that says what this rule means, in the page's own English. "
      .. "A rule with no sentence cannot be reviewed, cited, or argued with", what)
  end
  if #t.is < 12 then
    fail("%s: `is` is %q, which is too short to be a sentence someone else could check", what, t.is)
  end
end

local function check_message_repair(t, what)
  if type(t.message) ~= "string" or t.message == "" then
    fail("%s needs `message`: what is wrong, addressed to whoever owns the data", what)
  end
  if type(t.repair) ~= "string" or t.repair == "" then
    fail("%s needs `repair`: what to do about it. A finding with no repair is a complaint", what)
  end
end

local ALNUM = "^[%w]$"

-- The gate that does the real work. A mark must begin with a symbol the language does not
-- use, so a definite description has nowhere to go: there is no field for it, and a letter
-- is refused as a lead.
local function check_lead(lead, what)
  if lead == nil then
    fail("%s needs `lead`: one non-alphanumeric character that starts the mark. A reading with no mark "
      .. "of its own is language, and language is the map's - state it with interpret.means, which "
      .. "lets the reference layer do the matching", what)
  end
  if type(lead) ~= "string" or #lead ~= 1 then
    fail("%s: `lead` is exactly one character, got %s", what,
      type(lead) == "string" and ("%q"):format(lead) or type(lead))
  end
  if lead:match(ALNUM) then
    fail("%s: `lead` is %q, a letter or a digit. A mark begins with a symbol the language does not use, "
      .. "or it is indistinguishable from a word", what, lead)
  end
end

-- Checked after assembly, so a punctuation lead cannot launder an English phrase.
local function check_not_language(lead, word, what)
  if word == nil then return end
  local bare = word:gsub("[%p%s]", "")
  if bare ~= "" and bare:match("^%a+$") and #bare > 2 and lead:match("^[%-_%.]$") then
    fail("%s: %q behind a lead of %q is a hyphenated English phrase, not a mark. State it with "
      .. "interpret.means so the reference layer binds it", what, word, lead)
  end
end

-- A body holds only the MIDDLE of its function, exactly as a thing's body does: the header,
-- the annotations, `function(<arg>, host)`, `local found = {}` and `return found` are
-- rendered around it. A body that writes its own scaffold would be rendered twice.
local function check_body(body, what)
  if type(body) ~= "string" or body:match("^%s*$") then
    fail("%s: `body` is the middle of the rule's function, as Lua source", what)
  end
  if body:match("function%s*%(") and body:match("^%s*function") then
    fail("%s: `body` is the MIDDLE only - the scaffold (the header, the annotations, "
      .. "`function(...)`, `local found = {}` and `return found`) is rendered around it, so a body "
      .. "that opens its own function is rendered twice", what)
  end
  if body:match("^%s*return%s+found%s*$") then
    fail("%s: `body` is only `return found`, which the scaffold already writes. Give the middle that "
      .. "fills `found`, or give no body at all", what)
  end
end

-- ------------------------------------------------------------------------ the collection
--
-- A file declares many rules. They accumulate in order so the rendered module is stable
-- between Builds, which is what makes a diff of `.work/rules/rules.lua` readable.

local function new_book()
  return { order = {}, by_name = {} }
end

local book = new_book()

local function keep(rule)
  if book.by_name[rule.name] then
    fail("the rule %q is declared twice", rule.name)
  end
  book.by_name[rule.name] = rule
  book.order[#book.order + 1] = rule
  return rule
end

--- Every rule declared so far, in declaration order.
function interpret.rules()
  local out = {}
  for i = 1, #book.order do out[i] = book.order[i] end
  return out
end

--- Forget everything declared. For tests and for a second workspace in one process.
function interpret.reset()
  book = new_book()
end

-- ---------------------------------------------------------------------------- the surface

local function head(t, name, what)
  if type(name) ~= "string" or name == "" then fail("%s needs a name", what) end
  if type(t) ~= "table" then fail("%s %q takes a table, got %s", what, name, type(t)) end
  refuse_pattern_fields(t, ("%s %q"):format(what, name))
  check_is(t, ("%s %q"):format(what, name))
end

local function shape_of(t, name, what, allow_word)
  if t.shape ~= nil and not tagged(t.shape, "__shape") then
    fail("%s %q: `shape` is one of interpret.SHOUTED, WORD, NUMBER, DATE - a constant, not a string%s",
      what, name, type(t.shape) == "string"
        and ". A string cannot be a shape: that is how a regex would get in" or "")
  end
  if t.shape == interpret.WORD and not allow_word then
    fail("%s %q: a bare word is language. Give a `word` literal, or a formatted shape", what, name)
  end
  return t.shape
end

--- A mark: notation this writer invented, which the parser sees nothing in.
function interpret.mark(name)
  return function (t)
    local what = "interpret.mark"
    head(t, name, what)
    local label = ("%s %q"):format(what, name)
    check_lead(t.lead, label)
    local shape = shape_of(t, name, what, true)
    if t.word ~= nil and type(t.word) ~= "string" then fail("%s: `word` is a literal string", label) end
    if t.word == nil and shape == nil then
      fail("%s: give a `word` (a literal that follows the lead) or a `shape` (what follows it looks like)", label)
    end
    check_not_language(t.lead, t.word, label)
    local tail = t.word and literal(t.word) or shape.pattern
    local tail_rust = t.word and literal_rust(t.word) or shape.rust
    return keep({
      kind = "notation", name = name, is = t.is,
      lead = t.lead, word = t.word, shape = shape and shape.name or nil,
      to = { kind = (t.means or interpret.VALUE).name, address = t.address or "" },
      -- Rendered, never authored. The author never wrote either string and cannot.
      -- `matches` is this process's; `pattern` is the store's, in Rust's syntax.
      matches = literal(t.lead) .. tail,
      pattern = literal_rust(t.lead) .. tail_rust,
      says = ("%s then %s"):format(t.lead, t.word and ("%q"):format(t.word) or shape.human),
      binds = { "build" },
    })
  end
end

--- A seam: an extra place a unit ends. Anchored, never free-floating.
function interpret.seam(name)
  return function (t)
    local what = "interpret.seam"
    head(t, name, what)
    local label = ("%s %q"):format(what, name)
    if t.at ~= interpret.LINE_START then
      fail("%s: `at` must be interpret.LINE_START. A seam that can open anywhere opens everywhere", label)
    end
    local shape = shape_of(t, name, what, false)
    if shape == nil then
      fail("%s: `shape` is required - a formatted token the line starts with (DATE or NUMBER)", label)
    end
    return keep({
      kind = "seam", name = name, is = t.is, shape = shape.name,
      matches = "^" .. shape.pattern,
      pattern = "(?m)^" .. shape.rust .. "\\b",
      says = ("a line starting with %s"):format(shape.human),
      binds = { "build" },
    })
  end
end

--- What the map should already be able to see: the phrase and the address it refers to.
--- Carries NO pattern, by design - the reference layer decides what refers to what, and
--- this supplies only the answer for the referent it names.
function interpret.means(phrase)
  return function (t)
    local what = "interpret.means"
    if type(phrase) ~= "string" or phrase == "" then fail("%s needs the phrase", what) end
    if type(t) ~= "table" then fail("%s %q takes a table", what, phrase) end
    local label = ("%s %q"):format(what, phrase)
    refuse_pattern_fields(t, label)
    if type(t.is) ~= "string" or t.is == "" then
      fail("%s needs `is`: the address the phrase refers to, as thing.field", label)
    end
    if not t.is:match("^[%w%-_]+%.?[%w%-_]*$") then
      fail("%s: `is` is an address like \"quiet-site.latest_board\", got %q", label, t.is)
    end
    return keep({
      kind = "row", name = t.name or phrase:gsub("%W+", "-"):gsub("^%-+", ""):gsub("%-+$", ""),
      is = t.says or ("%s always means %s"):format(phrase, t.is),
      phrase = phrase,
      to = { kind = (t.means or interpret.VALUE).name, address = t.is },
      by = "reference",   -- the map matches it; no pattern is rendered
      binds = { "build" },
    })
  end
end

--- A law: what the workspace's things must satisfy. Checked over the derived Turtle by a
--- SELECT binding each offender to ?s, or by a Manchester class expression whose members
--- are the offenders, or by a body.
function interpret.law(name)
  return function (t)
    local what = "interpret.law"
    head(t, name, what)
    local label = ("%s %q"):format(what, name)
    check_message_repair(t, label)
    local how = 0
    if t.select then how = how + 1 end
    if t.flag then how = how + 1 end
    if t.body then how = how + 1 end
    if how == 0 then
      fail("%s: a law needs one of `select` (a SELECT binding each offender to ?s), `flag` (a class "
        .. "expression whose members are the offenders) or `body` (the middle of a function)", label)
    end
    if how > 1 then
      fail("%s: a law states its offenders ONE way. Two disagree silently and nobody finds out which ran", label)
    end
    if t.select and not t.select:upper():match("SELECT") then
      fail("%s: `select` is a SPARQL SELECT, and this one has no SELECT in it", label)
    end
    if t.select and not t.select:match("%?s") then
      fail("%s: `select` must bind each offender to ?s - that is the variable the check runner reads", label)
    end
    if t.body then check_body(t.body, label) end
    if t.binds ~= nil and not tagged(t.binds, "__binds") then
      fail("%s: `binds` is one of interpret.BUILD, STORE, MIDDLE, HOST, AGENT", label)
    end
    if t.mode ~= nil and not tagged(t.mode, "__mode") then
      fail("%s: `mode` is interpret.FUNCTIONAL or interpret.CONTEXTUAL", label)
    end
    if t.advisory ~= nil and type(t.advisory) ~= "boolean" then
      fail("%s: `advisory` is true or false. Advisory informs; anything else gates", label)
    end
    return keep({
      kind = "law", name = name, is = t.is,
      sparql = t.select, flag = t.flag, body = t.body,
      message = t.message, repair = t.repair,
      advisory = t.advisory or false,
      binds = { (t.binds or interpret.STORE).name },
      mode = (t.mode or interpret.FUNCTIONAL).name,
    })
  end
end

--- A lint: a problem on a page, found by a body and reported where the writer is looking.
function interpret.lint(name)
  return function (t)
    local what = "interpret.lint"
    head(t, name, what)
    local label = ("%s %q"):format(what, name)
    check_message_repair(t, label)
    if t.select or t.flag then
      fail("%s: a lint reads a PAGE, so it has no SPARQL and no class expression - those run over the "
        .. "derived store, which is what a law is for", label)
    end
    check_body(t.body, label)
    return keep({
      kind = "lint", name = name, is = t.is, body = t.body,
      message = t.message, repair = t.repair,
      advisory = t.advisory or false,
      binds = { "build" }, mode = "functional",
    })
  end
end

-- ------------------------------------------------------------------------------- gate two
--
-- The syntax gate cannot catch a mark whose span happens to be language on some page. So
-- the rendered mark is tested against what the parse aligned, and a mark covering a span
-- the map gave a graph node is refused with the aligned word named.
--
-- `aligned` is a list of { text = <the page's bytes>, word = <the aligned word>, node = <var> }
-- handed in by the host; this function is pure so it can be tested with no parser.

--- Which declared rules the map can already read, and therefore may not be declared here.
---
--- The question is SPAN OVERLAP, not text matching, and the difference is the whole gate.
--- Testing a mark's pattern against an aligned node's own text almost never fires: the
--- aligner's spans rarely include the sigil a mark must lead with, so `%$tired` does not match
--- the aligned word "tired". Measured over seven real parses: 10 of 311 aligned spans contain
--- an at-sign or a dollar, so text matching would miss 97 per cent of collisions and report a
--- clean result. A gate that passes almost everything is worse than no gate, because it is
--- believed.
---
--- So the mark is fired against the PAGE, and each place it fires is checked against every
--- span the parse aligned. A mark whose extent overlaps an aligned node is covering language
--- the map can already read.
---
--- `text` is the page. `aligned` is a list of { node, word, from, to } in the same offset
--- convention as the page is indexed - character offsets, which is what the aligner emits
--- (mar-hldj: 278 of 278 correct by character, 140 of 278 by byte).
---
--- Returns a list of { name, word, node, at, why }; empty when every mark is genuinely
--- notation. A rule with no `matches` (interpret.means) is never refused: it declared no
--- pattern, which is the point of it.
function interpret.refused_by_map(rules, text, aligned)
  if type(text) == "table" then
    -- the two-argument form used to take (rules, aligned) and match text against text. It
    -- could not fire, so it is refused rather than quietly doing nothing.
    error("interpret.refused_by_map(rules, text, aligned): the page's own text is needed, because "
      .. "the gate is span overlap and not text matching - an aligned span never contains the "
      .. "sigil a mark leads with", 2)
  end
  local out = {}
  for i = 1, #rules do
    local r = rules[i]
    if r.matches then
      local at = 1
      while at <= #text do
        local from, to = text:find(r.matches, at)
        if not from then break end
        for j = 1, #aligned do
          local a = aligned[j]
          -- half-open spans, and the parse's are 0-based where Lua's find is 1-based
          if a.from and a.to and from <= a.to and a.from + 1 <= to then
            out[#out + 1] = {
              name = r.name, node = a.node, word = a.word, at = from,
              why = ("%s fires at character %d, over the span the parse aligned to %s (%q). That is "
                .. "language the map can already read, so the reading is the map's - state it with "
                .. "interpret.means instead"):format(r.name, from, a.node or "?", a.word or ""),
            }
            break
          end
        end
        if #out > 0 and out[#out].name == r.name then break end
        at = to + 1
      end
    end
  end
  return out
end

-- -------------------------------------------------------------------------------- render
--
-- To ta_agent::spec::Rule, field for field, ready for serde. Only the fields the Rust reads
-- are emitted; `says`, `lead`, `word`, `shape`, `phrase` and `by` are the author's own
-- record and stay out of the store.

local RUST_FIELDS = { "name", "kind", "is", "pattern", "to", "sparql", "flag",
                      "message", "repair", "advisory", "body", "binds", "mode" }

--- One rule as the store holds it.
function interpret.render(rule)
  local out = {}
  for i = 1, #RUST_FIELDS do
    local k = RUST_FIELDS[i]
    if rule[k] ~= nil then out[k] = rule[k] end
  end
  out.kind = rule.kind
  out.name = rule.name
  return out
end

--- Every declared rule, grouped as `.work/rules/rules.lua` holds them: seams, notation,
--- rows, laws, lint - in that order, which is the order they run in.
function interpret.book()
  local out = { seams = {}, notation = {}, rows = {}, laws = {}, lint = {} }
  local bucket = { seam = "seams", notation = "notation", row = "rows", law = "laws", lint = "lint" }
  for i = 1, #book.order do
    local r = book.order[i]
    local b = out[bucket[r.kind]]
    b[#b + 1] = interpret.render(r)
  end
  return out
end

-- ------------------------------------------------------------------------------ the load
--
-- A workspace's rules file is GENERATED Lua, and generated Lua is untrusted (ruled
-- 2026-09-04, after a model's middle ran curl on this Mac during an eval). So a declaration
-- is evaluated with no filesystem, no process, no network and no way to reach one.
--
-- This mirrors what ta-agent's Rust loader does for an agent: drop io and os, empty
-- package.path so `require` cannot search the disk, and remove dofile and loadfile, which
-- would put back the escape that dropping io just closed.
--
-- Rule 2 of the surface holds here: LOADING RUNS NOTHING. A declaration builds tables. A
-- law's or a lint's `body` is carried as SOURCE TEXT and is never compiled by this function,
-- so loading a hostile rules file cannot execute the hostile part.

local UNSAFE = { "io", "os", "dofile", "loadfile", "load", "loadstring", "require", "debug",
                 "collectgarbage", "rawset", "rawget", "newproxy" }

--- Evaluate a declaration in a sandbox and hand back the book it declared.
--- `chunk` is the file's source; `name` is what to call it in an error.
function interpret.load(chunk, name)
  if type(chunk) ~= "string" then fail("interpret.load takes the declaration's source") end
  name = name or "rules"

  local env = { interpret = interpret }
  -- The standard library a declaration may legitimately want, and nothing else. string and
  -- table are here because a `body` is often assembled from pieces; math because a law may
  -- state a bound.
  for _, k in ipairs({ "string", "table", "math", "pairs", "ipairs", "type", "tostring",
                       "tonumber", "select", "error", "assert", "next", "pcall", "unpack" }) do
    env[k] = _G[k]
  end
  env._G = env
  for _, k in ipairs(UNSAFE) do
    env[k] = nil
  end

  local fn, err
  if setfenv then                                   -- 5.1 and LuaJIT
    fn, err = loadstring(chunk, name)
    if fn then setfenv(fn, env) end
  else                                              -- 5.2 and later
    fn, err = load(chunk, name, "t", env)
  end
  if not fn then
    return nil, ("%s does not parse: %s"):format(name, tostring(err))
  end

  interpret.reset()
  local ok, ran = pcall(fn)
  if not ok then
    return nil, ("%s refused: %s"):format(name, tostring(ran))
  end
  return interpret.book(), nil
end

-- ------------------------------------------------------------------------------- the file
--
-- `.work/rules/rules.lua` as canvas/rules.rs renders it. Rendered, never authored: an edit
-- to that file is lost on the next Build. This is here so the surface can be checked
-- against what Build already produces, rather than against a description of it.

local HEADER = [[
-- The workspace's own rules, rendered from the ontology (.work/ontology.json). Tooling and the harness
-- read this file; nobody edits it — an edit here is lost on the next Build. A rule is an entry in the
-- store, cited to the page whose sentence states it (docs/PAGES.md, "Rules").
--
-- Five hooks, run at the seams the harness already has, in this order: seams (the cut), notation (the
-- map, before the learned notation table), rows (the map, after what a sentence introduces), laws (the
-- check runner) and lint (a page's problems). A body's `host` is declared in meta.lua.

local rules = {}
]]

local GROUPS = {
  { field = "seams",    gloss = "seams: an extra place a unit ends." },
  { field = "notation", gloss = "notation: a marking of this writer's, pinned to a kind — asked before the learned table." },
  { field = "rows",     gloss = "rows: a phrase this workspace always reads as one address." },
  { field = "laws",     gloss = "laws: what the workspace's things must satisfy." },
  { field = "lint",     gloss = "lint: a problem to report on a page." },
}

-- The order a rule's own fields are written in, so two Builds of the same store produce the
-- same bytes and a diff of the file is about the rules rather than about table iteration.
local FIELD_ORDER = { "name", "is", "pattern", "to", "sparql", "flag", "message", "repair", "advisory", "body", "binds", "mode" }

local function quote(v)
  -- A long bracket for anything with a newline, exactly as the renderer does, so a SPARQL
  -- query stays readable in the file instead of becoming one escaped line.
  if v:find("\n") then
    local eq = ""
    while v:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
    return "[[" .. v .. "]]"
  end
  return string.format("%q", v)
end

local function value(v, indent)
  local t = type(v)
  if t == "string" then return quote(v) end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "table" then
    local parts = {}
    if #v > 0 then
      for i = 1, #v do parts[#parts + 1] = value(v[i], indent) end
      return "{ " .. table.concat(parts, ", ") .. " }"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = ("%s = %s"):format(k, value(v[k], indent)) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return "nil"
end

--- The module `.work/rules/rules.lua` holds, as a string.
function interpret.render_file()
  local book = interpret.book()
  local out = { HEADER }
  for _, g in ipairs(GROUPS) do
    local rows = book[g.field]
    out[#out + 1] = ("\n-- %s\nrules.%s = {"):format(g.gloss, g.field)
    for i = 1, #rows do
      local r = rows[i]
      out[#out + 1] = ("\n  -- %s\n  {"):format(r.is or r.name)
      -- Build omits a field that is the default for its kind, so the file holds what the
      -- workspace SAID and not what the schema fills in. Rendering the defaults would make
      -- every rule look hand-tuned and would diff against what Build actually writes.
      local default_binds = ({ law = "store", lint = "build", seam = "build", notation = "build", row = "build" })[r.kind]
      for _, k in ipairs(FIELD_ORDER) do
        local skip = (k == "advisory" and r[k] == false)
          or (k == "mode" and r[k] == "functional")
          or (k == "binds" and type(r[k]) == "table" and #r[k] == 1 and r[k][1] == default_binds)
        if r[k] ~= nil and not skip then
          out[#out + 1] = ("\n    %s = %s,"):format(k, value(r[k], "    "))
        end
      end
      out[#out + 1] = "\n  },"
    end
    out[#out + 1] = "\n}\n"
  end
  out[#out + 1] = "\nreturn rules\n"
  return table.concat(out)
end

-- ------------------------------------------------------------------ the surface is closed
--
-- A misspelled constant must not arrive as `nil`. In Lua `interpret.SHOUTD` and an omitted
-- field are the same value, so a typo would be reported as "you forgot a shape" - which
-- sends the author looking in the wrong place, and invites them to reach for a string.

local known = {}
for k in pairs(interpret) do known[k] = true end

local function nearest(k)
  local best, score, up = nil, 0, k:upper()
  for name in pairs(known) do
    local n = 0
    for i = 1, math.min(#name, #k) do
      if name:upper():sub(i, i) == up:sub(i, i) then n = n + 1 else break end
    end
    if n > score and n >= 2 then best, score = name, n end
  end
  return best
end

setmetatable(interpret, {
  __index = function (_, k)
    local near = nearest(k)
    error(("interpret.%s is not part of this surface%s. The shapes are SHOUTED, WORD, NUMBER and DATE; "
      .. "the anchor is LINE_START; a mark means VALUE, FLAG or STEP. There is no shape for \"anything\", "
      .. "because a mark that needs one is a grammar, and a grammar belongs to the map")
      :format(k, near and (" - did you mean interpret." .. near .. "?") or ""), 2)
  end,
  __newindex = function (_, k)
    error(("interpret is not extensible at run time, so `interpret.%s = ...` is refused. The surface is "
      .. "the five kinds and their constants, and it is closed on purpose"):format(k), 2)
  end,
})

return interpret
