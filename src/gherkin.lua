-- gherkin -- a feature file, read. Text in, pickles out.
--
-- Rule 7 of DESIGN.md lives here: this file may not name an agent, a tool, a port, a
-- world, a result or a run, and it requires nothing else in this tree. That is what lets
-- the reader be measured against four hundred real feature files with no harness present.
--
-- Two halves, and they do not know about each other:
--
--   1. PARSE AND PICKLE. `pickle(text)` answers the flat list a runner walks: backgrounds
--      merged in front, outlines expanded one scenario per row, tags inherited. Cucumber's
--      own compilation, in one pass.
--   2. EXPRESSIONS. `expr(text)` compiles a cucumber expression over five parameter types
--      into something that matches a step's text and answers its arguments, typed.
--
-- Every refusal is `nil, sentence` with the line number in it, because a person is going
-- to open the file. A malformed feature never raises; calling this with a number does.
--
-- Contract: spec/gherkin.md. Amend that before this diverges from it.

local gherkin = {}

-- small helpers

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function q(s) return string.format("%q", tostring(s)) end

-- A sentence about a line. Every refusal in this file goes through here, so every
-- refusal carries a number.
local function at(line, fmt, ...)
  return nil, string.format("line %d: " .. fmt, line, ...)
end

-- the keywords

-- The six step keywords, longest first so `* ` never shadows anything and `And ` is not
-- read as a description. The trailing space is part of the keyword: `Givenx` is prose.
local STEP_KEYWORDS = { "Given ", "When ", "Then ", "And ", "But ", "* " }

-- The block keywords. `Example:` is `Scenario:` and `Scenario Template:` is
-- `Scenario Outline:`; both spellings are Cucumber's and both appear in the wild.
local BLOCKS = {
  { word = "Feature:",           kind = "feature"    },
  { word = "Background:",        kind = "background" },
  { word = "Rule:",              kind = "rule"       },
  { word = "Scenario Outline:",  kind = "outline"    },
  { word = "Scenario Template:", kind = "outline"    },
  { word = "Scenario:",          kind = "scenario"   },
  { word = "Example:",           kind = "scenario"   },
  { word = "Examples:",          kind = "examples"   },
  { word = "Scenarios:",         kind = "examples"   },
}

-- What kind of line this is, and what it carries. Indentation is ignored for structure,
-- as it is in real Gherkin.
local function classify(raw)
  local line = trim(raw)
  if line == "" then return "blank" end
  if line:sub(1, 1) == "#" then return "comment", line end
  if line:sub(1, 1) == "@" then return "tags", line end
  if line:sub(1, 1) == "|" then return "row", line end
  local fence = line:match('^"""(.*)$') or line:match("^```(.*)$")
  if fence then return "fence", fence, raw:match("^(%s*)") end
  for i = 1, #BLOCKS do
    local b = BLOCKS[i]
    if line:sub(1, #b.word) == b.word then
      return b.kind, trim(line:sub(#b.word + 1))
    end
  end
  for i = 1, #STEP_KEYWORDS do
    local k = STEP_KEYWORDS[i]
    if line:sub(1, #k) == k then
      return "step", trim(line:sub(#k + 1)), (k:gsub("%s+$", ""))
    end
  end
  return "text", line
end

-- `@a @b` -> { "@a", "@b" }
local function tags_of(line)
  local out = {}
  for tag in line:gmatch("@%S+") do out[#out + 1] = tag end
  return out
end

-- `| a | b |` -> { "a", "b" }, with the two escapes Gherkin defines. Written character by
-- character rather than by splitting on `|`, because splitting cannot see `\|`.
local function cells_of(line)
  local out, cell, i = {}, {}, 1
  local chars = {}
  for c in line:gmatch(".") do chars[#chars + 1] = c end
  -- Everything before the first bar and after the last is not a cell.
  while i <= #chars and chars[i] ~= "|" do i = i + 1 end
  i = i + 1
  while i <= #chars do
    local c = chars[i]
    if c == "\\" and chars[i + 1] then
      local n = chars[i + 1]
      if n == "|" then cell[#cell + 1] = "|"
      elseif n == "n" then cell[#cell + 1] = "\n"
      elseif n == "\\" then cell[#cell + 1] = "\\"
      else cell[#cell + 1] = "\\"; cell[#cell + 1] = n end
      i = i + 2
    elseif c == "|" then
      out[#out + 1] = trim(table.concat(cell))
      cell = {}
      i = i + 1
    else
      cell[#cell + 1] = c
      i = i + 1
    end
  end
  -- A trailing fragment after the last bar is whitespace in a well-formed row, and is
  -- dropped rather than becoming a phantom cell.
  return out
end

-- parsing

local function new_step(keyword, text, line)
  return { keyword = keyword, text = text, line = line }
end

-- The document, as blocks. Not public as it is: `pickle` is the door a runner uses, and
-- `document` below answers a copy of the blocks and nothing about a description, because a
-- caller who held the tree would start depending on the shape of one.
local function parse(text)
  if type(text) ~= "string" then
    error("gherkin.pickle: a feature is a string, and arrived as " .. type(text), 3)
  end

  -- A UTF-8 byte order mark, which two of the four hundred real feature files in
  -- `vendor/rgpair` begin with. Real Gherkin strips it; a reader that does not reports
  -- the first line as a foreign keyword, which is a true sentence about a false problem.
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end

  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

  local doc = { tags = {}, rules = {}, background = nil, scenarios = {} }
  local seen_feature = false
  local pending_tags = nil
  local rule = nil                 -- the open Rule:, or nil at feature level
  local block = nil                -- the open background/scenario/outline
  local examples = nil             -- the open Examples: of an outline
  local n = 1

  -- Where a step or an Examples: row goes right now.
  local function target() return block end

  while n <= #lines do
    local raw = lines[n]
    local kind, payload, extra = classify(raw)

    if kind == "blank" or kind == "comment" then
      -- `# language: fr` is Gherkin's own way of saying this file is not English, and
      -- refusing it by name is why comments are inspected at all.
      if kind == "comment" then
        local lang = payload:match("^#%s*language%s*:%s*([%w%-]+)")
        if lang and lang:lower() ~= "en" then
          return at(n, "this tree reads English Gherkin only, and this file declares `%s`", lang)
        end
      end
      n = n + 1

    elseif kind == "tags" then
      -- ACCUMULATED, never replaced. Gherkin lets a construct carry as many tag lines as
      -- it likes, and real feature files use that -- `@dataservice` on one line and
      -- `@list-environments` on the next, both belonging to the Feature below them. A
      -- reader that overwrites keeps the last line and silently drops the rest.
      local more = tags_of(payload)
      if pending_tags then
        for i = 1, #more do pending_tags[#pending_tags + 1] = more[i] end
      else
        pending_tags = more
      end
      n = n + 1

    elseif kind == "feature" then
      if seen_feature then
        return at(n, "a file holds one `Feature:`, and this is the second")
      end
      seen_feature = true
      doc.name, doc.line = payload, n
      doc.tags = pending_tags or {}
      pending_tags, block, rule, examples = nil, nil, nil, nil
      n = n + 1

    elseif not seen_feature then
      -- The first construct in the file must be `Feature:`. This is where a localised
      -- keyword lands, and saying so is worth more than any amount of guessing.
      return at(n, "expected `Feature:`, found %s — this tree reads English Gherkin only", q(trim(raw)))

    elseif kind == "rule" then
      rule = { name = payload, line = n, tags = pending_tags or {}, background = nil, scenarios = {} }
      doc.rules[#doc.rules + 1] = rule
      pending_tags, block, examples = nil, nil, nil
      n = n + 1

    elseif kind == "background" then
      if pending_tags then
        return at(n, "a `Background:` takes no tags; it is not a scenario")
      end
      block = { kind = "background", name = payload, line = n, steps = {} }
      examples = nil
      if rule then
        if rule.background then return at(n, "this `Rule:` already has a `Background:`") end
        rule.background = block
      else
        if doc.background then return at(n, "this feature already has a `Background:`") end
        if #doc.scenarios > 0 or #doc.rules > 0 then
          return at(n, "a `Background:` comes before the scenarios it applies to")
        end
        doc.background = block
      end
      n = n + 1

    elseif kind == "scenario" or kind == "outline" then
      block = { kind = kind, name = payload, line = n, tags = pending_tags or {},
                steps = {}, examples = {} }
      pending_tags, examples = nil, nil
      local into = rule and rule.scenarios or doc.scenarios
      into[#into + 1] = block
      n = n + 1

    elseif kind == "examples" then
      if not block or block.kind ~= "outline" then
        return at(n, "`Examples:` belongs to a `Scenario Outline:`, and this one has none above it")
      end
      examples = { name = payload, line = n, tags = pending_tags or {}, header = nil, rows = {} }
      pending_tags = nil
      block.examples[#block.examples + 1] = examples
      n = n + 1

    elseif kind == "row" then
      local cells = cells_of(payload)
      if examples then
        if not examples.header then
          examples.header = cells
        else
          if #cells ~= #examples.header then
            return at(n, "this `Examples:` row has %d cells and its header has %d",
                      #cells, #examples.header)
          end
          examples.rows[#examples.rows + 1] = { cells = cells, line = n }
        end
      else
        local t = target()
        local step = t and t.steps[#t.steps]
        if not step then
          return at(n, "a data table belongs to the step above it, and there is none")
        end
        step.rows = step.rows or {}
        if #step.rows > 0 and #cells ~= #step.rows[1] then
          return at(n, "this data table row has %d cells and the first has %d",
                    #cells, #step.rows[1])
        end
        step.rows[#step.rows + 1] = cells
        step.last = n
      end
      n = n + 1

    elseif kind == "fence" then
      local t = target()
      local step = t and t.steps[#t.steps]
      if not step then
        return at(n, "a doc string belongs to the step above it, and there is none")
      end
      local indent = extra or ""
      local opener = trim(raw):sub(1, 3)
      local body, closed = {}, false
      local m = n + 1
      while m <= #lines do
        local candidate = trim(lines[m])
        if candidate == opener or (opener == '"""' and candidate == '"""')
           or (opener == "```" and candidate == "```") then
          closed = true
          break
        end
        -- Indentation is stripped to the opening fence's column, and no further: a line
        -- indented less than the fence keeps whatever it has rather than losing a
        -- character it needed.
        local line = lines[m]
        if #indent > 0 and line:sub(1, #indent) == indent then line = line:sub(#indent + 1) end
        body[#body + 1] = line
        m = m + 1
      end
      if not closed then
        return at(n, "this doc string is never closed")
      end
      step.doc = table.concat(body, "\n")
      step.doc_type = payload ~= "" and payload or nil
      step.last = m
      n = m + 1

    elseif kind == "step" then
      local t = target()
      if not t then
        -- A DESCRIPTION line that happens to open with a step keyword. Real Gherkin
        -- raises; this tree reads it as description, matching the divergence
        -- `canvas::scenarios` records on the Rust side. A feature's free description
        -- regularly runs to a sentence beginning "And ...", and refusing those costs real
        -- files.
        -- After a scenario has opened there is a container, so a step is a step.
        pending_tags = nil
        n = n + 1
      else
      if pending_tags then
        return at(n, "a step takes no tags")
      end
      t.steps[#t.steps + 1] = new_step(extra, payload, n)
      n = n + 1
      end

    else   -- "text": a description line
      if pending_tags then
        return at(n, "these tags belong to nothing: %s follows them", q(trim(raw)))
      end
      n = n + 1
    end
  end

  if not seen_feature then
    return nil, "this file has no `Feature:`"
  end
  return doc
end

-- compilation

local function copy_steps(steps)
  local out = {}
  for i = 1, #steps do
    local s = steps[i]
    local rows = nil
    if s.rows then
      rows = {}
      for r = 1, #s.rows do
        local row = {}
        for c = 1, #s.rows[r] do row[c] = s.rows[r][c] end
        rows[r] = row
      end
    end
    out[i] = { keyword = s.keyword, text = s.text, line = s.line, doc = s.doc,
               doc_type = s.doc_type, rows = rows }
  end
  return out
end

local function join(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for i = 1, #(list or {}) do out[#out + 1] = list[i] end
  end
  return out
end

-- `<column>` everywhere in a step, including inside a doc string and a data table. A
-- column the Examples: does not have is a refusal, not an empty string, because the
-- silent version of this mistake is a scenario that tests nothing.
-- What can be a placeholder at all. A column may be named with spaces, so this cannot be
-- an identifier; it must exclude ordinary text that happens to sit between `<` and `>`,
-- such as `$lhs <= $rhs AS lte, $lhs >` inside a doc string of Cypher.
--
-- The rule: a placeholder holds no whitespace and no punctuation beyond `_ - .`. Anything
-- else is text, left as written. A `<who>` the Examples lacks is still refused -- that one
-- is a typo, and the silent version of it is a scenario that tests nothing.
local function placeholder_shaped(name)
  return name:match("^[%w_][%w_%-%.]*$") ~= nil
end

local function substitute(text, values, line)
  local missing = nil
  local out = text:gsub("<([^<>]+)>", function (name)
    local v = values[name]
    if v == nil then
      if placeholder_shaped(name) then missing = missing or name end
      return "<" .. name .. ">"
    end
    return v
  end)
  if missing then
    return nil, string.format("line %d: this outline has no `%s` column", line, missing)
  end
  return out
end

local function expand(step, values)
  local out = { keyword = step.keyword, line = step.line, doc_type = step.doc_type }
  local text, why = substitute(step.text, values, step.line)
  if not text then return nil, why end
  out.text = text
  if step.doc then
    local doc
    doc, why = substitute(step.doc, values, step.line)
    if not doc then return nil, why end
    out.doc = doc
  end
  if step.rows then
    out.rows = {}
    for r = 1, #step.rows do
      local row = {}
      for c = 1, #step.rows[r] do
        local cell
        cell, why = substitute(step.rows[r][c], values, step.line)
        if not cell then return nil, why end
        row[c] = cell
      end
      out.rows[r] = row
    end
  end
  return out
end

--- Every scenario in `text`, compiled flat: backgrounds in front, outlines expanded,
--- tags inherited. `nil, sentence` on a feature this tree will not read.
function gherkin.pickle(text)
  local doc, why = parse(text)
  if not doc then return nil, why end

  local out = {}

  local function add(scenario, rule)
    local base = join(doc.background and doc.background.steps or {},
                      rule and rule.background and rule.background.steps or {})
    local tags = join(doc.tags, rule and rule.tags or {}, scenario.tags)

    if scenario.kind == "scenario" then
      -- A scenario with no steps of its own pickles with NO steps at all, not the
      -- background's, exactly as Cucumber's compiler does. It is a scenario somebody
      -- named and did not write, and the runner reports it undefined.
      local steps = #scenario.steps == 0 and {} or join(copy_steps(base), copy_steps(scenario.steps))
      out[#out + 1] = { name = scenario.name, line = scenario.line, tags = tags, steps = steps }
      return true
    end

    if #scenario.examples == 0 then
      return nil, string.format("line %d: a `Scenario Outline:` needs an `Examples:`", scenario.line)
    end
    for e = 1, #scenario.examples do
      local ex = scenario.examples[e]
      if not ex.header then
        return nil, string.format("line %d: this `Examples:` has no header row", ex.line)
      end
      for r = 1, #ex.rows do
        local values = {}
        for c = 1, #ex.header do values[ex.header[c]] = ex.rows[r].cells[c] end
        local steps = copy_steps(base)
        for i = 1, #scenario.steps do
          local step, bad = expand(scenario.steps[i], values)
          if not step then return nil, bad end
          steps[#steps + 1] = step
        end
        if #scenario.steps == 0 then steps = {} end
        -- The NAME takes the row too. `Scenario Outline: Add two numbers <num1> & <num2>`
        -- names four different scenarios, and a report that called all four by the
        -- unsubstituted name would be a report a person cannot act on.
        local name, bad = substitute(scenario.name, values, scenario.line)
        if not name then return nil, bad end
        out[#out + 1] = { name = name, line = ex.rows[r].line,
                          tags = join(tags, ex.tags), steps = steps }
      end
    end
    return true
  end

  for i = 1, #doc.scenarios do
    local ok, bad = add(doc.scenarios[i], nil)
    if not ok then return nil, bad end
  end
  for r = 1, #doc.rules do
    local rule = doc.rules[r]
    for i = 1, #rule.scenarios do
      local ok, bad = add(rule.scenarios[i], rule)
      if not ok then return nil, bad end
    end
  end
  return out
end

--- The blocks of `text`, each with its OWN steps: the feature's name and tags, its
--- background, its scenarios and its rules (each with a background and scenarios). For a
--- reader that needs a block apart from what pickling merges into it -- the lines a
--- background says once, or a scenario's lines without the background in front. Every
--- step carries `line`, and `last` when a doc string or table runs past it.
--- `nil, sentence` on a feature this tree will not read.
function gherkin.document(text)
  local doc, why = parse(text)
  if not doc then return nil, why end
  local function steps_of(list)
    local out = copy_steps(list)
    for i = 1, #list do out[i].last = list[i].last or list[i].line end
    return out
  end
  local function tags_of_block(t)
    local out = {}
    for i = 1, #(t or {}) do out[i] = t[i] end
    return out
  end
  local function block(b)
    if not b then return nil end
    return { name = b.name, line = b.line, kind = b.kind, tags = tags_of_block(b.tags),
             steps = steps_of(b.steps) }
  end
  local function scenarios(list)
    local out = {}
    for i = 1, #list do out[i] = block(list[i]) end
    return out
  end
  local out = { name = doc.name, line = doc.line, tags = tags_of_block(doc.tags),
                background = block(doc.background), scenarios = scenarios(doc.scenarios),
                rules = {} }
  for r = 1, #doc.rules do
    local rule = doc.rules[r]
    out.rules[r] = { name = rule.name, line = rule.line, tags = tags_of_block(rule.tags),
                     background = block(rule.background), scenarios = scenarios(rule.scenarios) }
  end
  return out
end

-- JSON, small
--
-- `{value}` needs to decode JSON and nothing in this tree does. Sixty lines here keeps
-- rule 7 absolute: this file requires nothing at all.

local decode_value

local function skip_ws(s, i)
  while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end
  return i
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
                  n = "\n", r = "\r", t = "\t" }

local function decode_string(s, i)
  local quote = s:sub(i, i)
  local out = {}
  i = i + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      local n = s:sub(i + 1, i + 1)
      if n == "u" then
        -- One BMP escape, as a codepoint the caller will almost never have. Anything
        -- above the BMP is left as written rather than half-decoded.
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if cp and cp < 128 then out[#out + 1] = string.char(cp)
        else out[#out + 1] = "\\u" .. hex end
        i = i + 6
      else
        out[#out + 1] = ESCAPES[n] or n
        i = i + 2
      end
    elseif c == quote then
      return table.concat(out), i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return nil
end

local function decode_array(s, i)
  local out = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "]" then return out, i + 1 end
  while true do
    local v
    v, i = decode_value(s, i)
    if i == nil then return nil end
    out[#out + 1] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "]" then return out, i + 1 end
    if c ~= "," then return nil end
    i = skip_ws(s, i + 1)
  end
end

local function decode_object(s, i)
  local out = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "}" then return out, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then return nil end
    local key
    key, i = decode_string(s, i)
    if key == nil then return nil end
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then return nil end
    local v
    v, i = decode_value(s, skip_ws(s, i + 1))
    if i == nil then return nil end
    out[key] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "}" then return out, i + 1 end
    if c ~= "," then return nil end
    i = skip_ws(s, i + 1)
  end
end

decode_value = function (s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i) end
  if c == '"' then return decode_string(s, i) end
  if s:sub(i, i + 3) == "true"  then return true,  i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null"  then return nil,   i + 4 end
  local num = s:match("^%-?%d+%.?%d*[eE]?[%-%+]?%d*", i)
  if num and num ~= "" and tonumber(num) then return tonumber(num), i + #num end
  return nil
end

--- JSON, or a bare number, or a quoted string, or the text as written.
function gherkin.value(text)
  local t = trim(text)
  local v, rest = decode_value(t, 1)
  if rest and skip_ws(t, rest) > #t and (v ~= nil or t == "null") then return v end
  return t
end

-- expressions
--
-- A cucumber expression compiles into a list of segments, and matching walks them with
-- backtracking. Not into one pattern: Lua patterns have no alternation, and `{value}` is
-- four alternatives before it is anything else.

local READERS = {}

READERS.string = function (s, i)
  local quote = s:sub(i, i)
  if quote ~= '"' and quote ~= "'" then return nil end
  local out, n = {}, i + 1
  while n <= #s do
    local c = s:sub(n, n)
    if c == "\\" and s:sub(n + 1, n + 1) ~= "" then
      out[#out + 1] = ESCAPES[s:sub(n + 1, n + 1)] or s:sub(n + 1, n + 1)
      n = n + 2
    elseif c == quote then
      return table.concat(out), n + 1
    else
      out[#out + 1] = c
      n = n + 1
    end
  end
  return nil
end

READERS.word = function (s, i)
  local w = s:match("^%S+", i)
  if not w then return nil end
  return w, i + #w
end

READERS.int = function (s, i)
  local n = s:match("^[%-%+]?%d+", i)
  if not n then return nil end
  return tonumber(n), i + #n
end

READERS.float = function (s, i)
  local n = s:match("^[%-%+]?%d+%.%d+", i) or s:match("^[%-%+]?%d+", i)
  if not n then return nil end
  return tonumber(n) + 0.0, i + #n
end

-- The one that is not standard Cucumber, because half of what a step says about an agent
-- is an argument table.
READERS.value = function (s, i)
  local c = s:sub(i, i)
  if c == "{" or c == "[" or c == '"' then
    local v, rest = decode_value(s, i)
    if rest then return v, rest end
    if c == '"' then return READERS.string(s, i) end
    return nil
  end
  if c == "'" then return READERS.string(s, i) end
  local n = s:match("^[%-%+]?%d+%.%d+", i) or s:match("^[%-%+]?%d+", i)
  if n then return tonumber(n), i + #n end
  local w = s:match("^%S+", i)
  if not w then return nil end
  if w == "true" then return true, i + 4 end
  if w == "false" then return false, i + 5 end
  return w, i + #w
end

local TYPES = { string = true, word = true, int = true, float = true, value = true }

-- Compile: literals, optionals `(s)`, alternations `a/an`, and parameters `{type}`.
local function compile(text)
  local segs, lit, i = {}, {}, 1
  local function flush()
    if #lit > 0 then segs[#segs + 1] = { kind = "lit", text = table.concat(lit) }; lit = {} end
  end
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      lit[#lit + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    elseif c == "{" then
      local name, rest = text:match("^{([%a_]*)}()", i)
      if not name then return nil, "an unclosed `{` in " .. q(text) end
      if not TYPES[name] then
        return nil, string.format("%s is not a parameter type; the five are {string} {word} {int} {float} {value}",
                                  "{" .. name .. "}")
      end
      flush()
      segs[#segs + 1] = { kind = "param", type = name }
      i = rest
    elseif c == "(" then
      local inner, rest = text:match("^%(([^%)]*)%)()", i)
      if not inner then return nil, "an unclosed `(` in " .. q(text) end
      flush()
      segs[#segs + 1] = { kind = "opt", text = inner }
      i = rest
    else
      lit[#lit + 1] = c
      i = i + 1
    end
  end
  flush()

  -- Alternation is a property of a word inside a literal, so it is resolved after the
  -- literals are whole: `a/an thing` is two ways to say one segment.
  local out = {}
  for s = 1, #segs do
    local seg = segs[s]
    if seg.kind == "lit" and seg.text:find("/", 1, true) then
      -- Split into the alternating word and the text around it, keeping the rest literal.
      local before, choices, after = seg.text:match("^(.-)(%S*/%S*)(.*)$")
      if before and choices then
        if before ~= "" then out[#out + 1] = { kind = "lit", text = before } end
        local options = {}
        for opt in choices:gmatch("[^/]+") do options[#options + 1] = opt end
        out[#out + 1] = { kind = "alt", options = options }
        if after ~= "" then out[#out + 1] = { kind = "lit", text = after } end
      else
        out[#out + 1] = seg
      end
    else
      out[#out + 1] = seg
    end
  end
  return out
end

-- Walk the segments against `s` from `i`, collecting arguments. Backtracks, because an
-- optional and an alternation each fork.
local function walk(segs, s, i, k, args)
  if k > #segs then
    if i > #s then return args end
    return nil
  end
  local seg = segs[k]
  if seg.kind == "lit" then
    if s:sub(i, i + #seg.text - 1) ~= seg.text then return nil end
    return walk(segs, s, i + #seg.text, k + 1, args)
  elseif seg.kind == "opt" then
    if s:sub(i, i + #seg.text - 1) == seg.text then
      local got = walk(segs, s, i + #seg.text, k + 1, args)
      if got then return got end
    end
    return walk(segs, s, i, k + 1, args)
  elseif seg.kind == "alt" then
    for o = 1, #seg.options do
      local opt = seg.options[o]
      if s:sub(i, i + #opt - 1) == opt then
        local got = walk(segs, s, i + #opt, k + 1, args)
        if got then return got end
      end
    end
    return nil
  else
    local v, rest = READERS[seg.type](s, i)
    if rest == nil then return nil end
    local n = #args + 1
    args[n] = v
    args.n = n
    local got = walk(segs, s, rest, k + 1, args)
    if got then return got end
    args[n] = nil
    args.n = n - 1
    return nil
  end
end

--- Compile one cucumber expression. `nil, sentence` on an expression this tree will not
--- read — which includes a regex, because there is no field here that takes one.
function gherkin.expr(text)
  if type(text) ~= "string" then
    error("gherkin.expr: an expression is a string, and arrived as " .. type(text), 2)
  end
  local segs, why = compile(text)
  if not segs then return nil, why end
  local e = { text = text, segs = segs }

  --- The arguments this expression reads out of `s`, or nil. A table, possibly empty,
  --- because an expression with no parameters still matches.
  function e.match(s)
    if type(s) ~= "string" then return nil end
    local args = { n = 0 }
    return walk(segs, s, 1, 1, args)
  end

  --- The shape two expressions collide on: every parameter erased to its type. Two
  --- expressions with one skeleton are the same expression written twice.
  function e.skeleton()
    local out = {}
    for i = 1, #segs do
      local seg = segs[i]
      if seg.kind == "lit" then out[#out + 1] = seg.text
      elseif seg.kind == "opt" then out[#out + 1] = "(" .. seg.text .. ")"
      elseif seg.kind == "alt" then out[#out + 1] = "/"
      else out[#out + 1] = "{}" end
    end
    return table.concat(out)
  end

  return e
end

return gherkin
