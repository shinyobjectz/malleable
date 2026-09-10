-- The interpret surface, tested by trying to break it. Every refusal below is a way an
-- author or an agent might get a reading of ordinary language into the interpretive layer;
-- each must be refused at DECLARATION, not caught later. mar-i182 under mar-4o07.

local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/]*$", ""))
local interpret = dofile(here .. "../src/interpret.lua")
local T = {}

local function refuses(fn, want, label)
  local ok, err = pcall(fn)
  assert(not ok, ("%s: expected a refusal, got none"):format(label))
  assert(tostring(err):find(want, 1, true),
    ("%s: refusal did not mention %q\n  got: %s"):format(label, want, tostring(err)))
end

local IS = "This sentence states the rule in the page's own English."

-- ------------------------------------------------------------------- the central refusal

-- The case the whole design exists to stop. A definite description has no field to be
-- written into: `lead` is required and a letter cannot be one.
function T.a_definite_description_cannot_be_expressed_at_all()
  interpret.reset()
  refuses(function () interpret.mark "board" { is = IS, word = "the board" } end,
    "needs `lead`", "no lead")
  refuses(function () interpret.mark "board" { is = IS, lead = "t", word = "he board" } end,
    "a letter or a digit", "a letter as the lead")
  local ok, err = pcall(function () interpret.mark "board" { is = IS, word = "the board" } end)
  assert(not ok and tostring(err):find("interpret.means", 1, true), "the refusal names the replacement")
end

-- Every name a pattern might arrive under, on every kind, so an agent reaching for the
-- familiar field is told it does not exist rather than being silently ignored.
function T.no_field_on_any_kind_accepts_a_pattern()
  interpret.reset()
  for _, k in ipairs({ "pattern", "regex", "match", "matches", "re", "glob", "expr", "rx" }) do
    refuses(function () interpret.mark "x" { is = IS, lead = "$", shape = interpret.SHOUTED, [k] = "[Tt]he board" } end,
      "never will be", "mark." .. k)
  end
  refuses(function () interpret.seam "x" { is = IS, at = interpret.LINE_START, shape = interpret.DATE, regex = "x" } end,
    "never will be", "seam.regex")
  refuses(function () interpret.law "x" { is = IS, message = "m", repair = "r", select = "SELECT ?s", pattern = "x" } end,
    "never will be", "law.pattern")
  refuses(function () interpret.means "the board" { is = "a.b", glob = "*" } end,
    "never will be", "means.glob")
end

-- A shape is a constant held by identity; a string cannot be one, and a typo fails at
-- ACCESS with the near miss named rather than arriving as nil.
function T.a_shape_is_a_constant_and_a_typo_fails_at_access()
  interpret.reset()
  refuses(function () interpret.mark "x" { is = IS, lead = "$", shape = "[A-Za-z ]+" } end,
    "that is how a regex would get in", "a string shape")
  refuses(function () return interpret.ANYTHING end, "is not part of this surface", "a shape that does not exist")
  refuses(function () return interpret.SHOUTD end, "did you mean interpret.SHOUTED", "a near miss")
  refuses(function () interpret.NEW = 1 end, "not extensible", "adding to the surface")
end

-- The one free-text field is escaped, so a metacharacter in it is a character.
function T.a_literal_word_is_escaped_and_never_compiled()
  interpret.reset()
  local m = interpret.mark "dotted" { is = IS, lead = "$", word = "a.b" }
  assert(m.matches == "%$a%.b", m.matches)
  assert(("$axb"):match(m.matches) == nil, "a full stop must not match any character")
  assert(("$a.b"):match(m.matches) ~= nil, "a full stop matches a full stop")
  interpret.reset()
  local alt = interpret.mark "alt" { is = IS, lead = "$", word = "a|b" }
  assert(("$a"):match(alt.matches) == nil, "a pipe is not alternation")
end

function T.punctuation_does_not_launder_an_english_phrase()
  interpret.reset()
  refuses(function () interpret.mark "board" { is = IS, lead = "-", word = "theboard" } end,
    "interpret.means", "a hyphen plus an English word")
end

-- ------------------------------------------------------------------- every rule says itself

function T.every_kind_needs_the_sentence_that_states_it()
  interpret.reset()
  refuses(function () interpret.mark "x" { lead = "$", word = "y" } end, "needs `is`", "mark without a sentence")
  refuses(function () interpret.seam "x" { at = interpret.LINE_START, shape = interpret.DATE } end,
    "needs `is`", "seam without a sentence")
  refuses(function () interpret.law "x" { select = "SELECT ?s", message = "m", repair = "r" } end,
    "needs `is`", "law without a sentence")
  refuses(function () interpret.mark "x" { is = "too short", lead = "$", word = "y" } end,
    "too short to be a sentence", "a sentence that is not one")
end

function T.a_finding_states_what_is_wrong_and_what_to_do()
  interpret.reset()
  refuses(function () interpret.law "x" { is = IS, select = "SELECT ?s" } end, "needs `message`", "no message")
  refuses(function () interpret.law "x" { is = IS, select = "SELECT ?s", message = "m" } end,
    "A finding with no repair is a complaint", "no repair")
end

-- --------------------------------------------------------------------------------- laws

function T.a_law_states_its_offenders_exactly_one_way()
  interpret.reset()
  refuses(function () interpret.law "x" { is = IS, message = "m", repair = "r" } end,
    "needs one of `select`", "no method")
  refuses(function () interpret.law "x" { is = IS, message = "m", repair = "r",
    select = "SELECT ?s", flag = "type:debt" } end, "ONE way", "two methods")
  refuses(function () interpret.law "x" { is = IS, message = "m", repair = "r", select = "?s a type:debt" } end,
    "no SELECT in it", "not a SELECT")
  refuses(function () interpret.law "x" { is = IS, message = "m", repair = "r", select = "SELECT ?x WHERE {}" } end,
    "bind each offender to ?s", "wrong variable")
end

function T.a_law_defaults_to_the_store_and_to_gating()
  interpret.reset()
  local l = interpret.law "debt-has-clearing" {
    is = "Every debt must state its clearing.",
    select = "SELECT ?s WHERE { ?s a type:debt }",
    message = "a debt without a stated clearing is a complaint, not a plan",
    repair = "add clearing: one sentence of what done looks like",
  }
  assert(l.binds[1] == "store", l.binds[1])
  assert(l.mode == "functional", l.mode)
  assert(l.advisory == false, "a law gates unless it says otherwise")
  interpret.reset()
  local a = interpret.law "open-debt" { is = "Every open debt prints on the ledger.",
    select = "SELECT ?s WHERE { ?s a type:debt }", message = "m", repair = "r",
    advisory = true, binds = interpret.HOST, mode = interpret.CONTEXTUAL }
  assert(a.advisory == true and a.binds[1] == "host" and a.mode == "contextual")
  refuses(function () interpret.law "y" { is = IS, select = "SELECT ?s", message = "m", repair = "r",
    binds = "store" } end, "one of interpret.BUILD", "binds as a string")
end

-- A body is the middle only. One that opens its own function is rendered twice.
function T.a_body_is_the_middle_and_not_the_scaffold()
  interpret.reset()
  refuses(function () interpret.lint "x" { is = IS, message = "m", repair = "r",
    body = "function(page, host)\n  return {}\nend" } end, "MIDDLE only", "a body with its own function")
  refuses(function () interpret.lint "x" { is = IS, message = "m", repair = "r", body = "return found" } end,
    "the scaffold already writes", "a body that is only the return")
  interpret.reset()
  local ok = interpret.lint "empty-heading" { is = "A heading with nothing under it is a problem.",
    message = "this heading says nothing", repair = "write a sentence under it or take it out",
    body = 'for i, line in ipairs(page.lines) do\n  if line:match("^#") then found[#found+1] = i end\nend' }
  assert(ok.kind == "lint" and ok.binds[1] == "build")
end

function T.a_lint_reads_a_page_and_a_law_reads_the_store()
  interpret.reset()
  refuses(function () interpret.lint "x" { is = IS, message = "m", repair = "r",
    select = "SELECT ?s", body = "x = 1" } end, "which is what a law is for", "a lint with SPARQL")
end

-- --------------------------------------------------------------------------------- seams

function T.a_seam_anchors_on_a_formatted_token()
  interpret.reset()
  refuses(function () interpret.seam "d" { is = IS, shape = interpret.DATE } end,
    "interpret.LINE_START", "unanchored")
  refuses(function () interpret.seam "d" { is = IS, at = interpret.LINE_START, shape = interpret.WORD } end,
    "a bare word is language", "a word at line start")
  refuses(function () interpret.seam "d" { is = IS, at = interpret.LINE_START } end,
    "`shape` is required", "no shape")
  interpret.reset()
  local s = interpret.seam "log date" { is = "A line starting with a date is its own item.",
    at = interpret.LINE_START, shape = interpret.DATE }
  assert(s.matches == "^%d%d%d%d%-%d%d%-%d%d", s.matches)
  assert(("2026-09-10 the round ran"):match(s.matches) ~= nil, "a date line is a seam")
  assert(("the round ran on 2026-09-10"):match(s.matches) == nil, "a date mid-line is not")
end

-- --------------------------------------------------------------------------------- means

function T.means_carries_no_pattern_and_defers_to_the_map()
  interpret.reset()
  local r = interpret.means "the board" { is = "quiet-site.latest_board" }
  assert(r.pattern == nil and r.matches == nil, "means must render no pattern")
  assert(r.by == "reference" and r.to.address == "quiet-site.latest_board")
  assert(r.kind == "row" and r.name == "the-board", r.name)
  assert(r.is:find("always means", 1, true), r.is)
  refuses(function () interpret.means "the board" { is = "not an address at all!" } end,
    "is an address like", "a sentence where an address belongs")
end

-- ------------------------------------------------------------- the corpus's own five marks

function T.the_marks_the_corpus_actually_uses_still_declare()
  interpret.reset()
  local hand = interpret.mark "hand-set value" {
    is = "Whenever we write a dollar and a name in capitals we mean a value we set by hand.",
    lead = "$", shape = interpret.SHOUTED, means = interpret.VALUE }
  assert(("$TYPEAWAY_URL"):match(hand.matches) ~= nil, "a hand-set value must still read")
  assert(("plain words here"):match(hand.matches) == nil, "and prose must not")
  local tired = interpret.mark "tired" {
    is = "A dollar-tired marks a route that has outlived its freshness window.",
    lead = "$", word = "tired", means = interpret.FLAG }
  assert(("$tired"):match(tired.matches) ~= nil)
  assert(tired.to.kind == "flag")
  local seam = interpret.seam "date line" { is = "A line starting with a date is its own item.",
    at = interpret.LINE_START, shape = interpret.DATE }
  assert(seam.matches ~= nil and seam.pattern ~= nil)
  -- and the fifth, which was English, now goes through the map
  local board = interpret.means "the board" { is = "quiet-site.latest_board" }
  assert(board.pattern == nil and board.matches == nil, "the fifth carries no pattern")
  assert(#interpret.rules() == 4)
end

-- ------------------------------------------------------------------------------ gate two

-- -------------------------------------------------------------------------------- render

function T.render_emits_the_stores_own_fields_and_nothing_else()
  interpret.reset()
  local m = interpret.mark "tired" { is = "A dollar-tired marks a stale route.", lead = "$", word = "tired" }
  local r = interpret.render(m)
  assert(r.kind == "notation" and r.name == "tired" and r.pattern == "\\$tired", tostring(r.pattern))
  assert(r.to.kind == "value")
  for _, gone in ipairs({ "lead", "word", "shape", "says", "by", "phrase" }) do
    assert(r[gone] == nil, ("the author's own record %q must stay out of the store"):format(gone))
  end
end

function T.the_book_groups_by_kind_in_the_order_they_run()
  interpret.reset()
  interpret.seam "d" { is = "A line starting with a date is its own item.", at = interpret.LINE_START, shape = interpret.DATE }
  interpret.mark "t" { is = "A dollar-tired marks a stale route.", lead = "$", word = "tired" }
  interpret.means "the board" { is = "quiet-site.latest_board" }
  interpret.law "l" { is = "Every debt must state its clearing.", select = "SELECT ?s WHERE {}", message = "m", repair = "r" }
  interpret.lint "p" { is = "A heading with nothing under it is a problem.", message = "m", repair = "r", body = "found[1] = 1" }
  local b = interpret.book()
  assert(#b.seams == 1 and #b.notation == 1 and #b.rows == 1 and #b.laws == 1 and #b.lint == 1,
    ("%d/%d/%d/%d/%d"):format(#b.seams, #b.notation, #b.rows, #b.laws, #b.lint))
end

function T.a_rule_declared_twice_is_refused()
  interpret.reset()
  interpret.mark "t" { is = "A dollar-tired marks a stale route.", lead = "$", word = "tired" }
  refuses(function () interpret.mark "t" { is = "A dollar-t marks something else entirely.", lead = "$", word = "t" } end,
    "declared twice", "the same name twice")
end

-- THE ACCEPTANCE. The four marks any workspace had actually declared, reproduced BYTE FOR
-- BYTE from the assembled surface. If these drift, the SDK is not expressing what the
-- corpus already states, and the migration would silently change every reading.
function T.the_rendered_pattern_is_byte_identical_to_what_the_corpus_states()
  interpret.reset()
  local hand = interpret.mark "value-set-by-hand" {
    is = "Whenever we write a dollar and a name in capitals we mean a value we set by hand.",
    lead = "$", shape = interpret.SHOUTED, means = interpret.VALUE }
  assert(hand.pattern == [[\$[A-Z][A-Z0-9_]*]], hand.pattern)     -- demo/site-status

  interpret.reset()
  local tired = interpret.mark "tired-mark" {
    is = "A dollar-tired marks a route that has outlived its freshness window.",
    lead = "$", word = "tired", means = interpret.FLAG }
  assert(tired.pattern == [[\$tired]], tired.pattern)             -- gen-harbor-room

  interpret.reset()
  local seam = interpret.seam "date-line" {
    is = "A line starting with a date is its own item.",
    at = interpret.LINE_START, shape = interpret.DATE }
  assert(seam.pattern == [[(?m)^\d{4}-\d{2}-\d{2}\b]], seam.pattern)  -- fixtures
end

-- The two renderings must never be confused. `matches` is a Lua pattern for this process;
-- `pattern` is a Rust regex for the store. Putting the Lua form where Rust compiles a regex
-- fails SILENTLY - "%$tired" is a percent, an anchor and a word, and matches nothing.
function T.the_store_never_receives_a_lua_pattern()
  interpret.reset()
  local m = interpret.mark "tired" { is = "A dollar-tired marks a stale route here.", lead = "$", word = "tired" }
  assert(m.matches:find("%", 1, true), "the in-process form is a Lua pattern")
  assert(not m.pattern:find("%", 1, true), "the store's form carries no Lua escape")
  assert(interpret.render(m).matches == nil, "`matches` must not reach the store")
end


-- ------------------------------------------------------- gate two, against REAL alignments
--
-- The fixtures under interpret-example/alignments/ are what the parser ACTUALLY produced for
-- corpus workspaces, generated by tools/interpret-alignments.py from their cached
-- meaning.json. A hand-written alignment proves nothing here: the question is whether real
-- parses contain the spans a careless mark collides with, and the first implementation of
-- this gate could not fire at all against real data.

local PAGES = {
  ["adv-clean-branch"] = "deliveries.md",
  ["adv-clean-ports"] = "stock.md",
}

local function fixture(ws)
  local aligned = dofile(here .. "alignments/" .. ws .. ".lua")
  local f = io.open(os.getenv("HOME") .. "/marble/corpus/" .. ws .. "/.work/pages/" .. PAGES[ws])
  if not f then return nil, aligned end
  local page = f:read("a"); f:close()
  return page, aligned
end

function T.real_alignments_load_and_carry_their_spans()
  local _, a = fixture("adv-clean-branch")
  assert(#a > 20, ("only %d aligned nodes"):format(#a))
  for _, r in ipairs(a) do
    assert(r.node and r.text and r.from and r.to, "every row carries its node and its span")
    assert(r.to >= r.from, "a span does not run backwards")
  end
end

-- THE GATE FIRES on a real parse. The page writes "@weigh puts the parcel on the scale" and
-- the parser aligned a node to "@weigh puts", so a mark reaching over @weigh is covering
-- language the map already reads.
function T.a_real_parse_catches_a_mark_that_covers_language()
  local page, a = fixture("adv-clean-branch")
  if not page then return end            -- the corpus workspace is untracked; skip rather than lie
  interpret.reset()
  local m = interpret.mark "weigh-mark" {
    is = "A mark that reaches over a mention the parse already reads.", lead = "@", word = "weigh" }
  assert(m.pattern ~= nil, "the syntax gate passes it - which is exactly why gate two exists")
  local bad = interpret.refused_by_map({ m }, page, a)
  assert(#bad == 1, "gate two must catch a mark over an aligned span")
  assert(bad[1].node == "s0_p", bad[1].node)
  assert(bad[1].why:find("interpret.means", 1, true), "the refusal names where the reading belongs")
end

-- AND IT STAYS QUIET on genuine notation: the parse placed nothing on a mark the writer
-- invented, because there is nothing there to place.
function T.real_parses_do_not_object_to_genuine_notation()
  for ws in pairs(PAGES) do
    local page, a = fixture(ws)
    if page then
      interpret.reset()
      local marks = {
        interpret.mark "tired" { is = "A dollar-tired marks a route past its window.", lead = "$", word = "tired" },
        interpret.mark "hand-set" { is = "A dollar and capitals mean a value we set by hand.",
          lead = "$", shape = interpret.SHOUTED },
      }
      local bad = interpret.refused_by_map(marks, page, a)
      assert(#bad == 0, ("%s objected to genuine notation: %s"):format(ws, bad[1] and bad[1].why or "?"))
    end
  end
end

-- The gate is SPAN OVERLAP, not text matching. The old form almost never fired: an aligned
-- span rarely contains the sigil a mark leads with. Measured over seven real parses, 10 of
-- 311 aligned spans hold an at-sign or a dollar - so text matching would miss 97 per cent of
-- collisions and report a clean result. The two-argument call is refused rather than quietly
-- returning nothing.
function T.the_old_text_matching_form_is_refused_rather_than_silently_empty()
  local _, a = fixture("adv-clean-branch")
  interpret.reset()
  local m = interpret.mark "x" { is = "A mark that leads with a dollar sign here.", lead = "$", word = "tired" }
  refuses(function () interpret.refused_by_map({ m }, a) end,
    "span overlap and not text matching", "the two-argument form")
  -- The premise, held as a live measurement rather than a claim in a comment: sigils are rare
  -- in aligned spans, so text matching would pass almost everything. If this ever rises, the
  -- old form stops being obviously wrong and this reasoning wants re-checking.
  local sigils, total = 0, 0
  for _, r in ipairs(a) do total = total + 1; if r.text:find("[@$]") then sigils = sigils + 1 end end
  assert(sigils / total < 0.25,
    ("%d of %d aligned spans contain a sigil; the gate's premise has changed"):format(sigils, total))
end

-- means declared no pattern, so gate two has nothing to test and never refuses it.
function T.gate_two_never_refuses_a_reading_that_declared_no_pattern()
  local page, a = fixture("adv-clean-branch")
  if not page then return end
  interpret.reset()
  local r = interpret.means "the parcel" { is = "weigh.parcel" }
  assert(#interpret.refused_by_map({ r }, page, a) == 0, "means has no pattern to collide with")
end

-- The two gates are independent, which is why there are two.
function T.the_two_gates_catch_different_things()
  interpret.reset()
  -- gate one, with no page at all
  refuses(function () interpret.mark "x" { is = "A mark with no lead of its own here.", word = "holds" } end,
    "needs `lead`", "gate one needs no page")
  -- gate two, on something gate one is right to allow
  local page, a = fixture("adv-clean-branch")
  if not page then return end
  interpret.reset()
  local m = interpret.mark "y" { is = "A mark over a mention the parser reads.", lead = "@", word = "weigh" }
  assert(#interpret.refused_by_map({ m }, page, a) == 1, "gate two catches it")
  assert(#interpret.refused_by_map({ m }, page, {}) == 0, "with no parse, nothing catches it")
end

-- ------------------------------------------------------------------------- the round trip
--
-- THE STRONGEST ACCEPTANCE AVAILABLE. Take the rules.lua Build actually produced, re-declare
-- every rule in it through this surface, render, and compare. If the two agree byte for
-- byte, the surface expresses exactly what the interpretive layer already holds - not an
-- approximation of it, and not a description of it in a doc that can drift.

local function real_rules()
  local path = os.getenv("HOME") .. "/marble/.work/rules/rules.lua"
  local f = io.open(path)
  if not f then return nil end
  local text = f:read("a"); f:close()
  local ok, book = pcall(dofile, path)
  if not ok then return nil end
  return text, book
end

function T.the_surface_renders_what_build_already_wrote_byte_for_byte()
  local text, book = real_rules()
  if not text then return end          -- no Build in this tree; skip rather than pass falsely
  interpret.reset()
  for _, l in ipairs(book.laws) do
    interpret.law (l.name) { is = l.is, select = l.sparql, message = l.message,
      repair = l.repair, advisory = l.advisory }
  end
  local mine = interpret.render_file()
  local function laws_of(s) return s:match("rules%.laws = {.-\n}\n") end
  local a, b = laws_of(mine), laws_of(text)
  assert(a and b, "both files carry a law block")
  if a ~= b then
    for n = 1, math.max(#a, #b) do
      if a:sub(n, n) ~= b:sub(n, n) then
        error(("the law block differs at byte %d\n  mine : %s\n  build: %s")
          :format(n, a:sub(math.max(1, n - 50), n + 50), b:sub(math.max(1, n - 50), n + 50)))
      end
    end
  end
  assert(#mine == #text, ("rendered %d bytes, Build wrote %d"):format(#mine, #text))
end

-- And what it renders is loadable Lua that reads back as the same rules, so the file is not
-- merely text that resembles the original.
function T.the_rendered_file_loads_and_reads_back_as_itself()
  interpret.reset()
  interpret.law "debt-has-clearing" { is = "Every debt must state its clearing.",
    select = "SELECT ?s WHERE {\n  ?s a type:debt .\n}\n",
    message = "a debt without a stated clearing is a complaint", repair = "add clearing" }
  interpret.mark "tired" { is = "A dollar-tired marks a stale route here.", lead = "$", word = "tired" }
  interpret.seam "date-line" { is = "A line starting with a date is its own item.",
    at = interpret.LINE_START, shape = interpret.DATE }
  local text = interpret.render_file()
  local fn, err = load(text)
  assert(fn, "the rendered module must be loadable Lua: " .. tostring(err))
  local back = fn()
  assert(#back.laws == 1 and #back.notation == 1 and #back.seams == 1,
    ("%d/%d/%d"):format(#back.laws, #back.notation, #back.seams))
  assert(back.laws[1].sparql:find("type:debt", 1, true), "a SPARQL query survives the round trip")
  assert(back.notation[1].pattern == [[\$tired]], back.notation[1].pattern)
  -- and the defaults Build omits are omitted here too
  assert(back.laws[1].mode == nil and back.laws[1].binds == nil,
    "a default binds or mode would make every rule look hand-tuned and diff against Build")
end

-- --------------------------------------------------------------------- the sandboxed load
--
-- A workspace's rules file is GENERATED Lua, and generated Lua is untrusted — ruled
-- 2026-09-04 after a model's middle ran curl on this machine during an eval. Loading a
-- declaration must not give it the disk, the process or the network.

function T.a_declaration_loads_and_returns_its_book()
  local book, err = interpret.load([[
interpret.mark "tired" { is = "A dollar-tired marks a stale route here.", lead = "$", word = "tired" }
interpret.law "clearing" { is = "Every debt must state its clearing.",
  select = "SELECT ?s WHERE { ?s a type:debt }", message = "a debt with no clearing", repair = "add one" }
]], "good")
  assert(book, tostring(err))
  assert(#book.notation == 1 and #book.laws == 1, ("%d/%d"):format(#book.notation, #book.laws))
end

function T.a_hostile_declaration_cannot_reach_the_machine()
  for _, hostile in ipairs({
    [[local f = io.open("/etc/passwd", "r")]],
    [[os.execute("curl http://example.com")]],
    [[os.remove("/tmp/anything")]],
    [[require("socket")]],
    [[dofile("/etc/passwd")]],
    [[loadfile("/etc/passwd")]],
    [[local g = load("return io")]],
    [[debug.getinfo(1)]],
  }) do
    local book, err = interpret.load(hostile, "hostile")
    assert(book == nil, ("this reached the machine: %s"):format(hostile))
    assert(err:find("nil", 1, true), ("refused for the wrong reason: %s"):format(err))
  end
end

-- The escape that dropping io alone would leave open: `require` searching the disk.
function T.package_paths_are_closed_so_require_cannot_search_the_disk()
  local book, err = interpret.load([[local p = package.path]], "probe")
  assert(book == nil and err:find("nil", 1, true), tostring(err))
end

-- Rule 2 of the surface: LOADING RUNS NOTHING. A law's body is carried as source text and is
-- never compiled here, so loading a hostile rules file cannot execute the hostile part.
function T.loading_never_runs_a_body()
  local book, err = interpret.load([[
interpret.lint "p" { is = "A heading with nothing under it is a problem.",
  message = "m", repair = "r", body = "error('a body must not run at load')" }
]], "bodied")
  assert(book, tostring(err))
  assert(#book.lint == 1, "the rule declared")
  assert(book.lint[1].body:find("must not run", 1, true), "and its body is carried as text")
end

function T.a_declaration_that_does_not_parse_says_so_rather_than_throwing()
  local book, err = interpret.load([[interpret.mark "x" {]], "broken")
  assert(book == nil and err:find("does not parse", 1, true), tostring(err))
end

function T.a_refused_declaration_carries_the_surfaces_own_reason()
  local book, err = interpret.load([[
interpret.mark "board" { is = "A mark with no lead of its own here.", word = "the board" }
]], "no-lead")
  assert(book == nil, "a refused declaration returns no book")
  assert(err:find("needs `lead`", 1, true), err)
  assert(err:find("interpret.means", 1, true), "and still names the replacement")
end

return T

