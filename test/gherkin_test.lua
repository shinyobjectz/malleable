-- gherkin: the reader. Text in, pickles out, and every refusal a sentence with a line
-- number in it.
--
-- The adversarial half is the half worth reading. A parser that reads the happy path is
-- a parser that turns a typo into a scenario nobody notices does not run.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local gherkin = require "gherkin"

local T = {}

local function feature(...)
  return table.concat({ ... }, "\n") .. "\n"
end

local function pickled(text)
  local p, why = gherkin.pickle(text)
  assert(p, tostring(why))
  return p
end

local function refused(text)
  local p, why = gherkin.pickle(text)
  assert(p == nil, "expected a refusal, got " .. tostring(p and #p) .. " pickles")
  assert(type(why) == "string" and why:match("^line %d+:") or why == "this file has no `Feature:`",
         "a refusal says which line: " .. tostring(why))
  return why
end

local function texts(pickle)
  local out = {}
  for i = 1, #pickle.steps do out[i] = pickle.steps[i].text end
  return table.concat(out, " | ")
end

-- ----------------------------------------------------------------------- the subset

function T.a_two_line_feature_is_a_feature()
  local p = pickled(feature("Feature: a", "  Scenario: b", "    Given c"))
  assert(#p == 1)
  assert(p[1].name == "b")
  assert(texts(p[1]) == "c")
  assert(p[1].steps[1].keyword == "Given")
end

function T.every_step_keyword_is_read_and_the_keyword_is_kept()
  local p = pickled(feature("Feature: a", "  Scenario: b",
    "    Given one", "    When two", "    Then three", "    And four", "    But five", "    * six"))
  local kinds = {}
  for i = 1, #p[1].steps do kinds[i] = p[1].steps[i].keyword end
  assert(table.concat(kinds, ",") == "Given,When,Then,And,But,*", table.concat(kinds, ","))
  -- `And` is NOT resolved to what it follows: a runner has to be able to print the line
  -- back the way it was written.
  assert(p[1].steps[4].keyword == "And")
end

function T.a_background_is_merged_in_front_of_every_scenario()
  local p = pickled(feature("Feature: a", "  Background:", "    Given base",
    "  Scenario: one", "    When x", "  Scenario: two", "    When y"))
  assert(#p == 2)
  assert(texts(p[1]) == "base | x", texts(p[1]))
  assert(texts(p[2]) == "base | y", texts(p[2]))
end

function T.a_rule_carries_its_own_background_and_tags()
  local p = pickled(feature("@top", "Feature: a", "  Background:", "    Given base",
    "  @ruled", "  Rule: r", "    Background:", "      Given rule base",
    "    @own", "    Scenario: one", "      When x"))
  assert(#p == 1)
  assert(texts(p[1]) == "base | rule base | x", texts(p[1]))
  assert(table.concat(p[1].tags, ",") == "@top,@ruled,@own", table.concat(p[1].tags, ","))
end

function T.example_is_scenario_and_template_is_outline()
  local p = pickled(feature("Feature: a", "  Example: b", "    Given c"))
  assert(#p == 1 and p[1].name == "b")
  p = pickled(feature("Feature: a", "  Scenario Template: b", "    Given <x>",
    "    Scenarios:", "      | x |", "      | 1 |"))
  assert(#p == 1 and texts(p[1]) == "1", texts(p[1]))
end

function T.an_outline_expands_one_scenario_per_row_everywhere_a_column_appears()
  local p = pickled(feature("Feature: a", "  Scenario Outline: b",
    "    Given <who> arrives with:", '      """', "      hello <who>", '      """',
    "    Then the table says", "      | name | <who> |",
    "    Examples:", "      | who |", "      | ana |", "      | bo  |"))
  assert(#p == 2, #p)
  assert(p[1].steps[1].text == "ana arrives with:")
  assert(p[1].steps[1].doc == "hello ana", p[1].steps[1].doc)
  assert(p[1].steps[2].rows[1][2] == "ana")
  assert(p[2].steps[1].doc == "hello bo")
  -- The line of an expanded scenario is the ROW's line, not the outline's: a failure
  -- points at the data that produced it.
  assert(p[1].line ~= p[2].line)
end

function T.a_doc_string_strips_to_the_fences_column_and_takes_both_fences()
  local p = pickled(feature("Feature: a", "  Scenario: b", "    Given c", '      """text/plain',
    "      one", "        two", "      ", '      """'))
  assert(p[1].steps[1].doc == "one\n  two\n", string.format("%q", p[1].steps[1].doc))
  assert(p[1].steps[1].doc_type == "text/plain")
  p = pickled(feature("Feature: a", "  Scenario: b", "    Given c", "      ```",
    "      one", "      ```"))
  assert(p[1].steps[1].doc == "one")
end

function T.a_data_table_unescapes_a_bar_and_a_newline()
  local p = pickled(feature("Feature: a", "  Scenario: b", "    Given c",
    "      | a\\|b | c\\nd |"))
  local row = p[1].steps[1].rows[1]
  assert(row[1] == "a|b", row[1])
  assert(row[2] == "c\nd", string.format("%q", row[2]))
end

function T.comments_blank_lines_and_indentation_are_not_structure()
  local p = pickled(feature("# a comment", "", "Feature: a", "", "   # another",
    "Scenario: b", "        Given c", ""))
  assert(#p == 1 and texts(p[1]) == "c")
end

function T.a_description_line_is_read_and_kept_out_of_the_steps()
  local p = pickled(feature("Feature: a", "  This feature is about a thing.",
    "  It has two sentences.", "  Scenario: b", "    Given c"))
  assert(#p == 1 and texts(p[1]) == "c")
end

function T.a_scenario_with_no_steps_pickles_with_no_steps_at_all()
  -- Not the background's. Cucumber's own compiler does this, and it is what lets a
  -- runner report "somebody named this and did not write it".
  local p = pickled(feature("Feature: a", "  Background:", "    Given base",
    "  Scenario: named but not written", "  Scenario: two", "    When x"))
  assert(#p == 2)
  assert(#p[1].steps == 0, #p[1].steps)
  assert(texts(p[2]) == "base | x")
end

-- ---------------------------------------------------------------------- the refusals

function T.a_second_feature_a_missing_one_and_a_foreign_one_are_all_refused()
  assert(refused(feature("Feature: a", "Feature: b")):match("second"))
  assert(refused(feature("  Scenario: b", "    Given c")):match("English Gherkin only"))
  assert(refused(feature("# language: fr", "Fonctionnalité: a")):match("`fr`"))
  local _, why = gherkin.pickle("# just a comment\n")
  assert(why == "this file has no `Feature:`", tostring(why))
end

function T.examples_under_a_plain_scenario_is_refused()
  assert(refused(feature("Feature: a", "  Scenario: b", "    Given c",
    "    Examples:", "      | x |", "      | 1 |")):match("belongs to a `Scenario Outline:`"))
end

function T.a_column_the_examples_does_not_have_is_refused_rather_than_left_empty()
  local why = refused(feature("Feature: a", "  Scenario Outline: b", "    Given <who> and <what>",
    "    Examples:", "      | who |", "      | ana |"))
  assert(why:match("no `what` column"), why)
end

function T.rows_that_differ_in_width_are_refused()
  assert(refused(feature("Feature: a", "  Scenario Outline: b", "    Given <x>",
    "    Examples:", "      | x | y |", "      | 1 |")):match("cells"))
  assert(refused(feature("Feature: a", "  Scenario: b", "    Given c",
    "      | 1 | 2 |", "      | 3 |")):match("cells"))
end

function T.a_doc_string_that_is_never_closed_is_refused()
  assert(refused(feature("Feature: a", "  Scenario: b", "    Given c", '    """', "    text"))
    :match("never closed"))
end

function T.an_outline_with_no_examples_and_a_stray_table_are_refused()
  assert(refused(feature("Feature: a", "  Scenario Outline: b", "    Given <x>"))
    :match("needs an `Examples:`"))
  assert(refused(feature("Feature: a", "  Scenario: b", "      | 1 |")):match("step above it"))
  assert(refused(feature("Feature: a", "  Scenario: b", '      """', '      """'))
    :match("step above it"))
end

function T.a_step_keyword_before_any_scenario_is_a_description_line()
  -- Real Gherkin raises here; this tree reads it as description, which is the same
  -- divergence the Rust reader records and the reason the two agree on the corpus. A
  -- feature's free description regularly runs to a sentence beginning "And ...".
  local p = pickled(feature("Feature: a", "  It does a thing.",
    "  And a snapshot is taken afterwards.", "  Scenario: b", "    Given c"))
  assert(#p == 1 and texts(p[1]) == "c", texts(p[1]))
end

function T.a_second_background_is_refused()
  assert(refused(feature("Feature: a", "  Background:", "    Given c",
    "  Background:", "    Given d")):match("already has a `Background:`"))
end

function T.a_byte_order_mark_is_not_a_foreign_keyword()
  local p = pickled("\239\187\191" .. feature("Feature: a", "  Scenario: b", "    Given c"))
  assert(#p == 1 and p[1].name == "b")
end

function T.angle_brackets_that_are_not_placeholders_are_left_as_written()
  -- `$lhs <= $rhs` inside a doc string of Cypher is text, not a column this outline is
  -- missing. A `<who>` it really is missing is still refused.
  local p = pickled(feature("Feature: a", "  Scenario Outline: b", "    Given <x> and:",
    '      """', "      RETURN $lhs <= $rhs AS lte", '      """',
    "    Examples:", "      | x |", "      | 1 |"))
  assert(p[1].steps[1].doc == "RETURN $lhs <= $rhs AS lte", p[1].steps[1].doc)
  assert(p[1].steps[1].text == "1 and:")
  assert(refused(feature("Feature: a", "  Scenario Outline: b", "    Given <who>",
    "    Examples:", "      | x |", "      | 1 |")):match("no `who` column"))
end

-- -------------------------------------------------------------------- the expressions

local function matched(expr, text)
  local e, why = gherkin.expr(expr)
  assert(e, tostring(why))
  return e.match(text)
end

function T.the_five_parameter_types_capture_and_type_what_they_say()
  local a = matched("the file {string} contains", [[the file "src/a.lua" contains]])
  assert(a.n == 1 and a[1] == "src/a.lua", tostring(a and a[1]))

  a = matched("it calls {word}", "it calls verdict")
  assert(a[1] == "verdict")

  a = matched("the budget is {int}", "the budget is -3")
  assert(a[1] == -3)

  a = matched("it took {float} seconds", "it took 1.5 seconds")
  assert(a[1] == 1.5)

  a = matched("with {value}", [[with {"path": "x", "n": 2}]])
  assert(type(a[1]) == "table" and a[1].path == "x" and a[1].n == 2)
end

function T.a_value_decodes_an_array_a_number_a_boolean_a_quoted_string_and_a_bare_word()
  assert(matched("with {value}", "with [1,2,3]")[1][2] == 2)
  assert(matched("with {value}", "with 7")[1] == 7)
  assert(matched("with {value}", "with true")[1] == true)
  assert(matched("with {value}", [[with "a b"]])[1] == "a b")
  assert(matched("with {value}", "with bare")[1] == "bare")
end

function T.optional_text_and_alternation_read_both_ways()
  assert(matched("it calls {word} {int} time(s)", "it calls a 1 time"))
  assert(matched("it calls {word} {int} time(s)", "it calls a 3 times"))
  assert(matched("a/an {word} arrives", "a bo arrives"))
  assert(matched("a/an {word} arrives", "an ana arrives"))
end

function T.an_expression_matches_the_whole_step_or_it_does_not_match()
  assert(matched("it stops with {word}", "it stops with answered"))
  assert(matched("it stops with {word}", "it stops with answered eventually") == nil)
  assert(matched("it calls {word}", "it calls a with 1") == nil)
end

function T.a_parameter_type_that_is_not_one_of_the_five_is_refused_by_name()
  local e, why = gherkin.expr("the {bogus} thing")
  assert(e == nil and why:match("is not a parameter type"), tostring(why))
  e, why = gherkin.expr("an unclosed {word")
  assert(e == nil and why:match("unclosed"), tostring(why))
end

function T.a_regex_is_not_a_thing_that_can_be_written_here()
  -- There is no field that takes one, so a regex compiles as the literal text it is and
  -- matches nothing but itself. That is the point: it fails visibly rather than working.
  local e = assert(gherkin.expr("^the .* thing$"))
  assert(e.match("the whole thing") == nil)
  assert(e.match("^the .* thing$") ~= nil)
end

function T.the_skeleton_is_what_two_expressions_collide_on()
  local a = assert(gherkin.expr("it calls {word} {int} time(s)"))
  local b = assert(gherkin.expr("it calls {string} {int} time(s)"))
  local c = assert(gherkin.expr("it calls {word} once"))
  assert(a.skeleton() == b.skeleton(), a.skeleton() .. " vs " .. b.skeleton())
  assert(a.skeleton() ~= c.skeleton())
end

function T.wrong_shapes_raise_rather_than_returning_a_refusal()
  -- A malformed feature is data and answers with a sentence; a number is a programmer
  -- error and raises.
  local ok = pcall(gherkin.pickle, 7)
  assert(not ok)
  ok = pcall(gherkin.expr, {})
  assert(not ok)
end

return T
