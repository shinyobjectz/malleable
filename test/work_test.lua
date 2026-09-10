-- work: plans, todos and checkpoints.
--
-- Everything here runs against the doubles and plain tables: no network, no disk, no
-- subprocess, no clock. Each test asserts with plain `assert` and says nothing when it
-- holds. The adversarial half is the half worth reading.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local work   = require "work"
local double = require "double"
local spec   = require "spec"

local T = {}

-- ------------------------------------------------------------------------ helpers

local function raised(fn, ...)
  local ok, message = pcall(fn, ...)
  return (not ok), tostring(message)
end

-- A port carrying only the fs slice, which is all of the world this module reaches.
local function world(files)
  local fs = double.fs(files)
  return { fs = fs }, fs
end

-- Wrap one fs call without touching the double, so a test can say exactly what the
-- world does wrong and where.
local function wrap(fs, call, fn)
  local out = {}
  for k, v in pairs(fs) do out[k] = v end
  out[call] = function (...) return fn(fs, ...) end
  return out
end

local function err_of(code, path)
  return { port = "fs", call = "read", code = code, message = code .. ": " .. path }
end

local function has(s, needle)
  return s:find(needle, 1, true) ~= nil
end

local function list_of(t)
  local seen = {}
  for i = 1, #t do seen[t[i]] = true end
  return seen
end

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return body
end

-- A mention that is not part of a longer word: "ratio." is not a reach for the real
-- world, and neither is "requirement".
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

-- The public prefix, built over the declaration surface exactly as a host builds it,
-- so `install` is exercised through the same door a declaration file uses.
local function prefix()
  local a = spec.new()
  local agent = {
    tool = function (name) return function (t) return spec.add_tool(a, name, t) end end,
    list = spec.types.list,
    string = spec.types.string,
    string_opt = spec.types.string_opt,
  }
  return agent, a
end

local function call(a, name, args)
  return a.tools[name].run { args = args }
end

-- The plan the specification renders, built once.
local function five()
  return work.plan {
    { text = "Read the turn loop", state = "done" },
    { text = "Find where a call is dispatched", state = "done" },
    { text = "Write the failing test", state = "doing" },
    { text = "Make it pass" },
    { text = "Update the changelog", state = "dropped", note = "not needed, it is generated" },
  }
end

local BLOCK = table.concat({
  "Plan (2/5)",
  "  1. [x] Read the turn loop",
  "  2. [x] Find where a call is dispatched",
  "  3. [>] Write the failing test",
  "  4. [ ] Make it pass",
  "  5. [-] Update the changelog -- not needed, it is generated",
}, "\n")

-- ------------------------------------------------------------------ the happy paths

function T.a_plan_renders_in_order()
  local plan = assert(five())
  assert(work.render(plan) == BLOCK, work.render(plan))
  assert(work.render(plan):sub(-1) ~= "\n", "a block ends without a trailing newline")

  local no_ids = work.render(plan, { ids = false })
  assert(has(no_ids, "  [x] Read the turn loop"))
  assert(not has(no_ids, "  1. "))

  local named = work.render(plan, { heading = "Todo" })
  assert(named:sub(1, 11) == "Todo (2/5)\n", named)
end

function T.an_empty_plan_is_a_plan()
  local plan = assert(work.plan {})
  assert(#plan.items == 0)
  assert(plan.revision == 1)
  assert(work.next(plan) == nil)
  local done, total, doing = work.progress(plan)
  assert(done == 0 and total == 0 and doing == nil)
  assert(work.render(plan) == "Plan (0/0)\n  (no items)", work.render(plan))

  -- And it takes a replacement like any other plan.
  assert(work.set(plan, { "one thing" }))
  assert(#plan.items == 1 and plan.items[1].id == "1")
end

function T.ids_are_minted_in_order_and_are_strings()
  local plan = assert(work.plan { "a", "b", "c" })
  assert(plan.items[1].id == "1")
  assert(plan.items[2].id == "2")
  assert(plan.items[3].id == "3")
  for i = 1, 3 do
    assert(type(plan.items[i].id) == "string")
    assert(plan.items[i].state == "todo")
    assert(plan.items[i].note == nil)
  end
  assert(plan.seq == 4)
end

function T.marking_moves_one_item_and_bumps_the_revision()
  local plan = assert(work.plan { "a", "b", "c" })
  local was = plan.revision
  local item = assert(work.mark(plan, "2", "done", "it was already there"))
  assert(item.id == "2" and item.state == "done")
  assert(item.note == "it was already there")
  assert(plan.revision == was + 1)
  local done, total = work.progress(plan)
  assert(done == 1 and total == 3)

  -- Every transition is allowed: reopening finished work must not need a whole
  -- restatement of the plan.
  assert(work.mark(plan, "2", "todo"))
  assert(plan.items[2].state == "todo")
  assert(plan.items[2].note == nil, "a mark with no note clears the one it replaces")
end

function T.next_prefers_the_item_in_flight()
  local plan = assert(work.plan { "a", "b", "c" })
  assert(work.next(plan).id == "1")
  assert(work.start(plan, "2"))
  assert(work.next(plan).id == "2", "the item in flight comes before any todo")
  assert(work.mark(plan, "2", "done"))
  assert(work.next(plan).id == "1")
  assert(work.mark(plan, "1", "done"))
  assert(work.mark(plan, "3", "done"))
  assert(work.next(plan) == nil, "a finished plan has nothing left to do")
end

function T.progress_ignores_dropped_items()
  local plan = assert(work.plan {
    { text = "a", state = "done" },
    { text = "b", state = "done" },
    { text = "c", state = "dropped" },
  })
  local done, total, doing = work.progress(plan)
  assert(done == 2 and total == 2 and doing == nil)
end

function T.replacing_keeps_the_state_of_an_unchanged_item()
  local plan = assert(work.plan { "a", "b", "c" })
  assert(work.mark(plan, "1", "done", "already there"))
  assert(work.start(plan, "2"))
  local was = plan.revision

  assert(work.set(plan, {
    { id = "1", text = "a" },
    { id = "2", text = "b" },
    { id = "3", text = "c" },
  }))
  assert(plan.revision == was + 1)
  assert(plan.items[1].state == "done" and plan.items[1].note == "already there")
  assert(plan.items[2].state == "doing")
  assert(plan.items[3].state == "todo")
  assert(plan.seq == 4, "nothing new was minted")

  -- The same id with different text is a different item wearing an old label.
  assert(work.set(plan, {
    { id = "1", text = "a, but differently" },
    { id = "2", text = "b" },
  }))
  assert(plan.items[1].state == "todo" and plan.items[1].note == nil)
  assert(plan.items[2].state == "doing")
  assert(#plan.items == 2, "an item no entry mentions is dropped from the list")
end

function T.taking_a_checkpoint_captures_bytes_verbatim()
  local odd = "one\0two\255three"          -- an embedded zero and no trailing newline
  local port, fs = world { ["a.txt"] = odd }
  local cp = assert(work.take(port, { "a.txt" }, { label = "edit a" }))
  assert(cp.count == 1 and cp.bytes == #odd)
  assert(cp.files[1].text == odd and cp.files[1].existed == true)

  assert(fs.write("a.txt", "clobbered"))
  local report = work.undo(port, cp)
  assert(report.restored == 1 and report.complete == true)
  assert(fs.read("a.txt") == odd, "the bytes come back exactly, zero byte included")
end

function T.undo_restores_a_changed_file()
  local port, fs = world { ["src/a.lua"] = "before" }
  local cp = assert(work.take(port, { "src/a.lua" }))
  assert(fs.write("src/a.lua", "after"))
  local report = work.undo(port, cp)
  assert(report.restored == 1 and report.removed == 0 and report.skipped == 0)
  assert(report.complete == true and #report.failed == 0)
  assert(fs.read("src/a.lua") == "before")
end

function T.undo_removes_a_file_the_turn_created()
  local port, fs = world {}
  local cp = assert(work.take(port, { "new.txt" }))
  assert(cp.files[1].existed == false and cp.files[1].text == nil)
  assert(fs.write("new.txt", "the turn wrote this"))
  assert(fs.exists("new.txt"))
  local report = work.undo(port, cp)
  assert(report.removed == 1 and report.restored == 0)
  assert(fs.exists("new.txt") == false)
end

function T.a_trail_mints_ids_and_reports_evictions()
  local port = world { ["a.txt"] = "x" }
  local trail = work.trail { cap = 8 }
  local first, ninth, all_evicted
  for i = 1, 9 do
    local cp = assert(work.take(port, { "a.txt" }, { label = "turn " .. i }))
    if i == 1 then first = cp end
    if i == 9 then ninth = cp end
    local _, evicted = work.push(trail, cp)
    if #evicted > 0 then all_evicted = evicted end
  end
  assert(first.id == "cp1" and ninth.id == "cp9")
  assert(#trail.items == 8)
  assert(all_evicted and #all_evicted == 1 and all_evicted[1] == first)
  assert(work.last(trail) == ninth)
  assert(work.pop(trail) == ninth)
  assert(#trail.items == 7)
end

function T.describe_is_one_stable_line()
  local port = world {
    ["src/turn.lua"] = string.rep("x", 4000),
    ["src/work.lua"] = string.rep("y", 210),
  }
  local cp = assert(work.take(port, { "src/turn.lua", "src/work.lua" },
                              { label = "edit src/turn.lua" }))
  assert(work.describe(cp) == '(unfiled) "edit src/turn.lua" -- 2 files, 4210 bytes',
         work.describe(cp))

  local trail = work.trail()
  work.push(trail, assert(work.take(port, { "src/work.lua" })))
  work.push(trail, cp)
  assert(work.describe(cp) == 'cp2 "edit src/turn.lua" -- 2 files, 4210 bytes', work.describe(cp))

  local bare = assert(work.take(port, { "src/work.lua" }))
  assert(work.describe(bare) == "(unfiled) -- 1 file, 210 bytes", work.describe(bare))
  assert(work.describe(cp) == work.describe(cp), "and it is the same line twice")
end

-- ------------------------------------------------------------------- adversarial

function T.a_partial_capture_is_no_capture()
  local port, fs = world { ["a.lua"] = "A", ["b.lua"] = "B", ["c.lua"] = "C" }
  port.fs = wrap(fs, "read", function (real, path)
    if path == "b.lua" then return nil, err_of("denied", path) end
    return real.read(path)
  end)

  local cp, reason, misses = work.take(port, { "a.lua", "b.lua", "c.lua" })
  assert(cp == nil, "a checkpoint missing one of three files is not a checkpoint")
  assert(type(reason) == "string" and has(reason, "b.lua"), tostring(reason))
  assert(type(misses) == "table" and #misses == 1)
  assert(misses[1].path == "b.lua")
  assert(misses[1].err.code == "denied", "the port's own error table comes through")
end

function T.a_missing_file_is_captured_not_refused()
  local port = world { ["a.lua"] = "A" }
  local cp = assert(work.take(port, { "a.lua", "gone.lua" }))
  assert(cp.count == 2 and cp.bytes == 1)
  local by_path = {}
  for i = 1, #cp.files do by_path[cp.files[i].path] = cp.files[i] end
  assert(by_path["gone.lua"].existed == false)
  assert(by_path["a.lua"].existed == true)
end

function T.an_empty_path_list_is_a_valid_checkpoint()
  local port = world {}
  local cp = assert(work.take(port, {}))
  assert(cp.count == 0 and cp.bytes == 0 and #cp.files == 0)
  local report = work.undo(port, cp)
  assert(report.restored == 0 and report.removed == 0 and report.skipped == 0)
  assert(report.complete == true and #report.failed == 0)
end

function T.duplicate_paths_are_captured_once()
  local port = world { ["a.lua"] = "A", ["b.lua"] = "BB" }
  local one = assert(work.take(port, { "a.lua", "a.lua", "a.lua" }))
  assert(one.count == 1 and one.bytes == 1)

  local two = assert(work.take(port, { "b.lua", "a.lua", "b.lua", "a.lua" }))
  local three = assert(work.take(port, { "a.lua", "b.lua" }))
  assert(two.count == 2 and three.count == 2)
  for i = 1, 2 do
    assert(two.files[i].path == three.files[i].path, "sorted, so two takes agree")
    assert(two.files[i].text == three.files[i].text)
  end
  assert(two.files[1].path == "a.lua")
end

function T.undo_does_not_merge()
  local port, fs = world { ["a.lua"] = "line one\n" }
  local cp = assert(work.take(port, { "a.lua" }))
  assert(fs.write("a.lua", "line one\nline two, a perfectly good edit\n"))
  local report = work.undo(port, cp)
  assert(report.restored == 1)
  assert(fs.read("a.lua") == "line one\n", "the appended line is gone, by design")
end

function T.undo_continues_past_a_failure_and_says_so()
  local port, fs = world { ["a.lua"] = "A", ["b.lua"] = "B", ["c.lua"] = "C" }
  local cp = assert(work.take(port, { "a.lua", "b.lua", "c.lua" }))
  fs.readonly = true

  local report = work.undo(port, cp)
  assert(type(report) == "table", "undo answers with a report, never with nil")
  assert(report.restored == 0)
  assert(#report.failed == 3, "every file was still attempted")
  assert(report.complete == false)
  local named = {}
  for i = 1, #report.failed do
    named[report.failed[i].path] = true
    assert(type(report.failed[i].reason) == "string")
  end
  assert(named["a.lua"] and named["b.lua"] and named["c.lua"])
end

function T.undo_is_idempotent()
  local port, fs = world { ["a.lua"] = "A", ["new.txt"] = nil }
  local cp = assert(work.take(port, { "a.lua", "new.txt" }))
  assert(fs.write("a.lua", "changed"))
  assert(fs.write("new.txt", "created"))

  local first = work.undo(port, cp)
  local second = work.undo(port, cp)
  assert(first.restored == second.restored and first.restored == 1)
  assert(first.removed == 1 and second.removed == 0)
  assert(second.skipped == 1, "the second run finds the created file already gone")
  assert(first.complete and second.complete)
  assert(fs.read("a.lua") == "A")
  assert(fs.exists("new.txt") == false)

  -- And the bytes do not move on a third run.
  local third = work.undo(port, cp)
  assert(third.restored == second.restored and third.removed == second.removed)
  assert(third.skipped == second.skipped)
  assert(fs.read("a.lua") == "A")
end

function T.a_port_that_raises_during_undo_becomes_a_failed_row()
  local port, fs = world { ["a.lua"] = "A", ["b.lua"] = "B", ["c.lua"] = "C" }
  local cp = assert(work.take(port, { "a.lua", "b.lua", "c.lua" }))
  assert(fs.write("a.lua", "x"))
  assert(fs.write("b.lua", "x"))
  assert(fs.write("c.lua", "x"))

  port.fs = wrap(fs, "write", function (real, path, text)
    if path == "b.lua" then error("this host's fs.write is broken") end
    return real.write(path, text)
  end)

  local report = work.undo(port, cp)
  assert(report.restored == 2 and #report.failed == 1)
  assert(report.failed[1].path == "b.lua")
  assert(has(report.failed[1].reason, "broken"), report.failed[1].reason)
  assert(report.complete == false)
  assert(fs.read("a.lua") == "A" and fs.read("c.lua") == "C")
end

function T.the_byte_cap_refuses_before_it_captures_everything()
  local files, paths = {}, {}
  for i = 1, 5 do
    local path = string.char(96 + i) .. ".txt"       -- a.txt .. e.txt
    files[path] = string.rep("z", 10)
    paths[i] = path
  end
  local port, fs = world(files)
  local reads = 0
  port.fs = wrap(fs, "read", function (real, path)
    reads = reads + 1
    return real.read(path)
  end)

  local cp, reason, misses = work.take(port, paths, { max_bytes = 25 })
  assert(cp == nil)
  assert(has(reason, "c.txt"), reason)
  assert(has(reason, "30"), reason)
  assert(has(reason, "25"), reason)
  assert(#misses == 0, "a cap is not a miss")
  assert(reads == 3, "the port was never asked for the fourth and fifth")
end

function T.the_file_cap_refuses_before_any_read()
  local port, fs = world { ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" }
  local reads = 0
  port.fs = wrap(fs, "read", function (real, path)
    reads = reads + 1
    return real.read(path)
  end)

  local cp, reason, misses = work.take(port, { "a.txt", "b.txt", "c.txt" }, { max_files = 2 })
  assert(cp == nil)
  assert(has(reason, "3") and has(reason, "2"), reason)
  assert(#misses == 0)
  assert(reads == 0, "a cap that only bites after doing all the work is not a cap")
end

function T.a_rejected_replacement_leaves_the_plan_alone()
  local plan = assert(work.plan { "a", "b", "c" })
  assert(work.mark(plan, "1", "done", "a note"))
  assert(work.start(plan, "3"))
  local revision, seq = plan.revision, plan.seq

  local ok, reason = work.set(plan, {
    { id = "1", text = "a" },
    { id = "2", text = "b" },
    { id = "3", text = "c" },
    { id = "4", text = 17 },
  })
  assert(ok == nil and has(reason, "item 4"), tostring(reason))
  assert(plan.revision == revision and plan.seq == seq)
  assert(#plan.items == 3)
  assert(plan.items[1].state == "done" and plan.items[1].note == "a note")
  assert(plan.items[3].state == "doing")
  assert(plan.items[1].text == "a" and plan.items[2].text == "b")

  -- And a list over the limit is told the limit and the count, never truncated.
  local many = {}
  for i = 1, 50 do many[i] = "item " .. i end
  local no, why = work.set(plan, many, { max_items = 32 })
  assert(no == nil and has(why, "50") and has(why, "32"), tostring(why))
  assert(#plan.items == 3)
end

function T.ids_are_never_recycled()
  local plan = assert(work.plan { "a", "b", "c" })
  assert(plan.seq == 4)
  assert(work.set(plan, { { id = "1", text = "a" }, { id = "3", text = "c" } }))
  assert(#plan.items == 2 and plan.items[2].id == "3")

  assert(work.set(plan, { { id = "1", text = "a" }, { id = "3", text = "c" }, "d" }))
  assert(plan.items[3].id == "4", "a stale id can never come to mean a different item")
  assert(plan.items[3].text == "d")

  -- An id the plan does not hold is a new item, and gets a fresh one.
  assert(work.set(plan, { { id = "2", text = "back again" } }))
  assert(plan.items[1].id == "5", plan.items[1].id)
end

function T.an_unknown_id_is_told_not_thrown()
  local plan = assert(work.plan { "a", "b" })
  local revision = plan.revision
  local item, reason = work.mark(plan, "99", "done")
  assert(item == nil and type(reason) == "string" and has(reason, "99"), tostring(reason))
  assert(plan.revision == revision and #plan.items == 2, "no item was invented")

  local agent, a = prefix()
  local installed = work.install(agent, { plan = plan })
  local out = call(a, installed.tools.mark, { id = "99", state = "done" })
  assert(type(out) == "string")
  assert(has(out, "99"), out)
  assert(has(out, "1. [ ] a"), "the ids that do exist are put in front of the model")
end

function T.two_items_cannot_be_in_flight()
  local plan = assert(work.plan { "a", "b", "c" })
  assert(work.start(plan, "1"))

  local item, reason = work.mark(plan, "2", "doing")
  assert(item == nil and has(reason, "1"), tostring(reason))
  assert(plan.items[2].state == "todo")

  local started, displaced = work.start(plan, "2")
  assert(started and started.id == "2" and displaced == "1")
  assert(plan.items[1].state == "todo")

  local again, none = work.start(plan, "2")
  assert(again == plan.items[2] and none == nil, "starting what is already doing is a no-op")

  local no, why = work.plan {
    { text = "a", state = "doing" },
    { text = "b", state = "doing" },
  }
  assert(no == nil and has(why, "item 2"), tostring(why))

  local nope = work.set(plan, {
    { id = "2", text = "b" },
    { id = "3", text = "c", state = "doing" },
  })
  assert(nope == nil, "a replacement carrying two in flight is refused too")
  assert(#plan.items == 3)
end

function T.text_is_never_used_to_match_an_item()
  local plan = assert(work.plan { "the same words", "the same words" })
  assert(work.mark(plan, "1", "done", "the first one"))
  assert(work.mark(plan, "2", "dropped", "the second one"))

  assert(work.set(plan, {
    { id = "2", text = "the same words" },
    { id = "1", text = "the same words" },
  }))
  assert(plan.items[1].id == "2" and plan.items[1].state == "dropped")
  assert(plan.items[1].note == "the second one")
  assert(plan.items[2].id == "1" and plan.items[2].state == "done")
  assert(plan.items[2].note == "the first one", "neither took the other's note")
end

function T.a_timeout_from_the_port_refuses_the_take()
  local port, fs = world { ["a.lua"] = "A", ["slow.lua"] = "S" }
  port.fs = wrap(fs, "read", function (real, path)
    if path == "slow.lua" then return nil, err_of("timeout", path) end
    return real.read(path)
  end)

  local cp, reason, misses = work.take(port, { "a.lua", "slow.lua" })
  assert(cp == nil and has(reason, "slow.lua"), tostring(reason))
  assert(#misses == 1 and misses[1].err.code == "timeout")
end

function T.nested_takes_do_not_share_state()
  local inner_port = world { ["inner.txt"] = "the inner bytes" }
  local outer_port, outer_fs = world { ["outer.txt"] = "the outer bytes", ["other.txt"] = "more" }

  local inner_cp
  outer_port.fs = wrap(outer_fs, "read", function (real, path)
    if path == "other.txt" then
      inner_cp = assert(work.take(inner_port, { "inner.txt" }, { label = "nested" }))
    end
    return real.read(path)
  end)

  local outer_cp = assert(work.take(outer_port, { "other.txt", "outer.txt" }))
  assert(inner_cp ~= nil and inner_cp.count == 1)
  assert(inner_cp.files[1].path == "inner.txt" and inner_cp.files[1].text == "the inner bytes")
  assert(outer_cp.count == 2)
  assert(outer_cp.files[1].path == "other.txt" and outer_cp.files[1].text == "more")
  assert(outer_cp.files[2].path == "outer.txt" and outer_cp.files[2].text == "the outer bytes")
  assert(outer_cp.bytes == #"more" + #"the outer bytes")

  -- And undo reaches nothing but the filesystem: no model, no shell, no gate, no clock.
  local w = double.world { fs = outer_fs }
  local report = work.undo(w, outer_cp)
  assert(report.complete == true)
  assert(#w.model.seen == 0 and #w.sh.ran == 0 and #w.ask.asked == 0)
  assert(#w.clock.slept == 0 and #w.log.lines == 0)
end

function T.two_plans_in_one_process_do_not_leak()
  local one = assert(work.plan { "a", "b" })
  local two = assert(work.plan { "x" })
  assert(work.mark(one, "1", "done"))
  assert(work.start(two, "1"))
  assert(work.set(one, { { id = "1", text = "a" }, "c" }))

  assert(one.seq == 4 and two.seq == 2)
  assert(one.revision == 3 and two.revision == 2)
  assert(#one.items == 2 and #two.items == 1)
  assert(one.items[1].state == "done" and two.items[1].state == "doing")
  assert(select(3, work.progress(one)) == nil)
  assert(select(3, work.progress(two)) == "1")

  local port = world { ["a.txt"] = "aaa", ["b.txt"] = "bb" }
  local left, right = work.trail { cap = 2 }, work.trail { cap = 8 }
  work.push(left, assert(work.take(port, { "a.txt" })))
  work.push(right, assert(work.take(port, { "b.txt" })))
  work.push(right, assert(work.take(port, { "a.txt", "b.txt" })))
  assert(left.seq == 2 and right.seq == 3)
  assert(left.bytes == 3 and right.bytes == 2 + 5)
  assert(work.last(left).id == "cp1" and work.last(right).id == "cp2")
end

function T.install_declares_two_tools_and_no_undo()
  local agent, a = prefix()
  local installed = work.install(agent)
  assert(installed.tools.plan == "plan" and installed.tools.mark == "mark")

  local schema = spec.schema(a)
  assert(#schema == 2, "two tools are declared, and only two")
  local named = {}
  for i = 1, #schema do
    named[schema[i].name] = schema[i]
    assert(not schema[i].name:find("undo", 1, true))
    assert(schema[i].ask == false, "a plan is a statement, not an action")
    assert(type(schema[i].about) == "string" and schema[i].about ~= "")
  end
  assert(named.plan and named.mark)

  -- Renaming is allowed; adding a third tool is not.
  local agent2, a2 = prefix()
  local renamed = work.install(agent2, { names = { plan = "todo_write" } })
  assert(renamed.tools.plan == "todo_write")
  assert(a2.tools.todo_write and a2.tools.mark and #a2.order == 2)

  local agent3 = prefix()
  local bad, message = raised(work.install, agent3, { names = { undo = "undo" } })
  assert(bad and has(message, "undo"), message)
end

function T.installing_runs_nothing()
  local port, fs = world { ["a.txt"] = "A" }
  local agent = prefix()
  local rang = false
  local installed = work.install(agent, { on_change = function () rang = true end })

  assert(rang == false, "declaring a tool does not run its body")
  assert(#fs.wrote == 0 and #fs.removed == 0)
  assert(installed.plan.revision == 1 and #installed.plan.items == 0)
  assert(port.fs == fs)
end

function T.an_on_change_that_raises_cannot_fail_a_tool_call()
  local agent, a = prefix()
  local entered = false
  local installed = work.install(agent, {
    on_change = function () entered = true; error("this host's renderer is broken") end,
  })

  local out = call(a, "plan", { items = { "write the test", "make it pass" } })
  assert(entered, "the renderer was called")
  assert(type(out) == "string" and has(out, "1. [ ] write the test"), out)
  assert(#installed.plan.items == 2, "and the change still stands")

  local marked = call(a, "mark", { id = "1", state = "doing" })
  assert(has(marked, "1. [>] write the test"), marked)
  assert(installed.plan.items[1].state == "doing")

  -- A rejected change does not call it at all.
  entered = false
  local refused = call(a, "plan", { items = { { text = "" } } })
  assert(has(refused, "item 1"), refused)
  assert(entered == false)
end

function T.wrong_shapes_raise_and_bad_worlds_return()
  local plan = assert(work.plan { "a" })
  local port, fs = world { ["a.lua"] = "A" }

  local bad, message = raised(work.plan, 7)
  assert(bad and has(message, "items"), message)

  bad, message = raised(work.mark, plan, 3, "done")
  assert(bad and has(message, "id"), message)

  bad, message = raised(work.mark, plan, "1", "finished")
  assert(bad and has(message, "state"), message)

  bad, message = raised(work.take, {}, { "a.lua" })
  assert(bad and has(message, "port"), message)

  bad, message = raised(work.take, port, "a.lua")
  assert(bad and has(message, "paths"), message)

  bad, message = raised(work.take, port, { 7 })
  assert(bad and has(message, "path 1"), message)

  bad, message = raised(work.undo, port, "cp")
  assert(bad and has(message, "cp"), message)

  bad, message = raised(work.trail, { cap = 0 })
  assert(bad and has(message, "cap"), message)

  bad = raised(work.set, "not a plan", {})
  assert(bad)

  bad = raised(function () work.defaults.max_items = 1 end)
  assert(bad, "the defaults are read to know a limit, never written into")
  assert(work.defaults.max_items == 32 and work.defaults.cap == 8)
  assert(work.defaults.max_text == 400 and work.defaults.max_files == 64)
  assert(work.defaults.max_bytes == 4194304)

  assert(#work.states == 4 and work.states[1] == "todo" and work.states[4] == "dropped")
  assert(work.states[2] == "doing" and work.states[3] == "done")
  bad = raised(function () work.states[5] = "wedged" end)
  assert(bad, "the set of states is closed and cannot grow")

  -- And the other channel: a world that misbehaves comes back as a value.
  port.fs = wrap(fs, "read", function (real, path)
    if path == "a.lua" then return nil, err_of("denied", path) end
    return real.read(path)
  end)
  local cp, reason = work.take(port, { "a.lua" })
  assert(cp == nil and type(reason) == "string")

  local item, why = work.mark(plan, "nope", "done")
  assert(item == nil and type(why) == "string")

  local report, empty = work.undo_last(port, work.trail())
  assert(report == nil and empty == "the trail is empty")
  assert(work.pop(work.trail()) == nil and work.last(work.trail()) == nil)
end

function T.work_touches_nothing_real()
  local body = read_file(here .. "/../src/work.lua")
  local reaches = {
    "io.", "os.time", "os.date", "os.clock", "os.execute", "os.getenv",
    "os.exit", "math.random", "print",
  }
  for i = 1, #reaches do
    assert(not mentions(body, reaches[i]),
           "src/work.lua reaches for " .. reaches[i])
  end
end

function T.work_requires_no_sibling()
  local body = read_file(here .. "/../src/work.lua")
  assert(not body:find("require", 1, true), "src/work.lua stands alone")
  local siblings = {
    "spec", "turn", "session", "port", "provider", "compaction", "tools_fs", "tools_shell",
  }
  for i = 1, #siblings do
    assert(not body:find('"' .. siblings[i] .. '"', 1, true),
           "src/work.lua names the sibling " .. siblings[i])
  end
end

function T.a_render_is_reproducible()
  local one = assert(work.plan {})
  assert(work.set(one, { "alpha", "beta", "gamma" }))
  assert(work.mark(one, "2", "done", "already there"))

  local two = assert(work.plan { "alpha", "beta", "gamma" })
  assert(work.mark(two, "2", "done", "already there"))

  local a, b = work.render(one), work.render(two)
  assert(a == b, a .. "\n~=\n" .. b)
  assert(work.render(one) == a, "and the same block twice from one plan")
  for i = 1, #a do
    assert(a:byte(i) < 128, "every byte of a rendered block is below 128")
  end

  -- A state this module does not know renders, rather than raising.
  one.items[1].state = "wedged"
  local odd = work.render(one)
  assert(has(odd, "[?] alpha"), odd)
  for i = 1, #odd do assert(odd:byte(i) < 128) end
end

-- --------------------------------------------- what the first pass left unexercised

function T.changed_says_what_an_undo_would_touch()
  local port, fs = world { ["kept.lua"] = "K", ["edited.lua"] = "E", ["locked.lua"] = "L" }
  local cp = assert(work.take(port, { "kept.lua", "edited.lua", "locked.lua", "gone.lua" }))
  assert(cp.count == 4)

  -- Nothing has moved yet, so nothing is changed and nothing is unknown.
  local changed, unknown = work.changed(port, cp)
  assert(#changed == 0 and #unknown == 0, "a checkpoint just taken matches the world")

  assert(fs.write("edited.lua", "E, and then some"))
  assert(fs.write("gone.lua", "the turn created this"))
  port.fs = wrap(fs, "read", function (real, path)
    if path == "locked.lua" then return nil, err_of("denied", path) end
    return real.read(path)
  end)

  changed, unknown = work.changed(port, cp)
  local moved, dark = list_of(changed), list_of(unknown)
  assert(#changed == 2 and moved["edited.lua"] and moved["gone.lua"],
         "a captured file that differs, and one that was absent and is now there")
  assert(not moved["kept.lua"], "a file with the captured bytes is not changed")
  assert(#unknown == 1 and dark["locked.lua"],
         "a path that will not read is unknown, never quietly counted clean")
  assert(not moved["locked.lua"])

  -- A captured file that has since been deleted is changed, not unknown.
  port.fs = fs
  assert(fs.remove("kept.lua"))
  changed = work.changed(port, cp)
  assert(list_of(changed)["kept.lua"], "existed then, absent now, is a change")

  -- It reads, and only reads: the preview does not perform the undo.
  local wrote = #fs.wrote
  work.changed(port, cp)
  assert(#fs.wrote == wrote and fs.read("edited.lua") == "E, and then some")
end

function T.undo_last_restores_the_newest_and_keeps_it_popped()
  local port, fs = world { ["a.lua"] = "A", ["b.lua"] = "B" }
  local trail = work.trail()
  work.push(trail, assert(work.take(port, { "a.lua" })))
  work.push(trail, assert(work.take(port, { "b.lua" })))
  assert(fs.write("a.lua", "x") and fs.write("b.lua", "y"))

  local report = assert(work.undo_last(port, trail))
  assert(report.restored == 1 and report.complete == true)
  assert(fs.read("b.lua") == "B", "the newest checkpoint is the one that came back")
  assert(fs.read("a.lua") == "x", "and only the newest: the older turn stands")
  assert(#trail.items == 1 and work.last(trail).id == "cp1")

  -- A restore that fails still pops: the report is the record, not the trail.
  fs.readonly = true
  local partial = assert(work.undo_last(port, trail))
  assert(partial.complete == false and #partial.failed == 1)
  assert(#trail.items == 0, "the checkpoint is not put back")
  local none, why = work.undo_last(port, trail)
  assert(none == nil and why == "the trail is empty", tostring(why))
end

function T.a_trail_is_bounded_by_bytes_as_well_as_by_count()
  local port = world {
    ["a.txt"] = string.rep("a", 10),
    ["b.txt"] = string.rep("b", 10),
  }
  local trail = work.trail { cap = 8, max_bytes = 25 }
  local first = assert(work.take(port, { "a.txt" }))
  local second = assert(work.take(port, { "b.txt" }))
  work.push(trail, first)
  work.push(trail, second)
  local _, evicted = work.push(trail, assert(work.take(port, { "a.txt", "b.txt" })))
  assert(#trail.items == 1 and trail.bytes == 20, trail.bytes)
  assert(#evicted == 2 and evicted[1] == first and evicted[2] == second,
         "evicted from the oldest end, in the order they went")

  -- A checkpoint over the bound on its own is kept anyway, and says so.
  local tight = work.trail { max_bytes = 4 }
  local big = assert(work.take(port, { "a.txt" }))
  local _, none = work.push(tight, big)
  assert(#none == 0 and #tight.items == 1 and tight.bytes == 10,
         "the turn about to rewrite a large file is the one most worth undoing")
  assert(tight.bytes > tight.max_bytes, "and the over-bound state is visible")

  -- Two trails holding one checkpoint cannot end up with two turns named alike.
  local left, right = work.trail(), work.trail()
  local shared = assert(work.take(port, { "b.txt" }))
  work.push(left, shared)
  work.push(right, shared)
  work.push(right, assert(work.take(port, { "a.txt" })))
  assert(shared.id == "cp1")
  assert(right.items[2].id ~= shared.id, right.items[2].id)
end

function T.a_render_narrows_a_byte_the_model_wrote()
  local text = "caf\xc3\xa9 \xe2\x80\x94 done"
  local plan = assert(work.plan { { text = text, state = "dropped", note = "\xffnope" } })
  local block = work.render(plan, { heading = "Pl\xe2\x80\x94an" })
  for i = 1, #block do
    assert(block:byte(i) < 128, "the block promises bytes below 128, heading included")
  end
  assert(has(block, "caf?? ??? done"), block)
  assert(has(block, " -- ?nope"), block)
  assert(plan.items[1].text == text, "the item keeps the bytes it was given")
  assert(plan.items[1].note == "\xffnope")
  assert(work.render(plan, { heading = "Pl\xe2\x80\x94an" }) == block, "and twice the same")
end

function T.a_fresh_plan_honours_the_ids_it_was_handed()
  local plan = assert(work.plan {
    { id = "7", text = "a" },
    "b",
    { id = "3", text = "c", state = "done" },
  })
  assert(plan.items[1].id == "7" and plan.items[3].id == "3")
  assert(plan.items[2].id ~= "7" and plan.items[2].id ~= "3", plan.items[2].id)
  assert(plan.items[3].state == "done", "a state stated in the entry is honoured")
  assert(plan.seq == 8, "seq ends past every id in the list: " .. tostring(plan.seq))

  -- So the next mint cannot collide with one of them.
  assert(work.set(plan, {
    { id = "7", text = "a" }, { id = "3", text = "c" }, "d",
  }))
  assert(plan.items[3].id == "8", plan.items[3].id)

  local no, why = work.plan { { id = "1", text = "a" }, { id = "1", text = "b" } }
  assert(no == nil and has(why, "item 2") and has(why, "1"), tostring(why))
end

function T.a_plan_sent_as_an_object_is_refused_not_obeyed()
  local agent, a = prefix()
  local installed = work.install(agent)
  assert(type(call(a, "plan", { items = { "write the test", "make it pass" } })) == "string")
  assert(#installed.plan.items == 2)
  local revision = installed.plan.revision

  -- A model that sends an object where an array belongs is told so. Reading it as an
  -- empty list would answer "no items" and throw away the plan it had.
  local out = call(a, "plan", { items = { first = "write the test" } })
  assert(has(out, "items is a list"), out)
  assert(has(out, "1. [ ] write the test"), out)
  assert(#installed.plan.items == 2, "the plan it stated is still there")
  assert(installed.plan.revision == revision, "and a refusal is not a change")

  -- The library says the same thing in its own channel: a shape fault raises.
  local bad, message = raised(work.set, installed.plan, { one = "a" })
  assert(bad and has(message, "items"), message)
  bad, message = raised(work.plan, { one = "a" })
  assert(bad and has(message, "items"), message)
  assert(work.plan {}, "and an empty list is still a list")
end

function T.a_malformed_checkpoint_stops_before_it_half_restores()
  local port, fs = world { ["a.lua"] = "A", ["b.lua"] = "B" }
  local cp = assert(work.take(port, { "a.lua", "b.lua" }))
  assert(fs.write("a.lua", "x") and fs.write("b.lua", "y"))
  local wrote = #fs.wrote

  table.insert(cp.files, 2, { text = "no path here", existed = true })
  local bad, message = raised(work.undo, port, cp)
  assert(bad and has(message, "file 2"), message)
  assert(#fs.wrote == wrote, "nothing was written before it stopped")
  assert(fs.read("a.lua") == "x" and fs.read("b.lua") == "y",
         "a raise from the middle of a restore is the one state undo exists to prevent")

  -- The same check guards the preview and the trail.
  assert(raised(work.changed, port, cp))
  assert(raised(work.push, work.trail(), cp))

  -- And with the bad row gone it restores everything, in one report.
  table.remove(cp.files, 2)
  local report = work.undo(port, cp)
  assert(report.restored == 2 and report.complete == true)
  assert(fs.read("a.lua") == "A" and fs.read("b.lua") == "B")
end

function T.a_note_on_the_item_in_flight_moves_the_revision()
  local agent, a = prefix()
  local installed = work.install(agent, { plan = assert(work.plan { "a", "b" }) })
  local plan = installed.plan

  local was = plan.revision
  call(a, "mark", { id = "1", state = "doing", note = "picking this up" })
  assert(plan.items[1].state == "doing" and plan.items[1].note == "picking this up")
  assert(plan.revision == was + 1, "starting an item is one change")

  was = plan.revision
  call(a, "mark", { id = "1", state = "doing", note = "still on it, for another reason" })
  assert(plan.items[1].note == "still on it, for another reason")
  assert(plan.revision == was + 1,
         "a note the host would render is a change, even when start was a no-op")

  was = plan.revision
  call(a, "mark", { id = "1", state = "doing", note = "still on it, for another reason" })
  assert(plan.revision == was, "and saying the same thing twice is not")

  -- Displacing carries the note of the mark that asked for it, and leaves the other's.
  call(a, "mark", { id = "2", state = "doing" })
  assert(plan.items[2].state == "doing" and plan.items[2].note == nil)
  assert(plan.items[1].state == "todo")
  assert(plan.items[1].note == "still on it, for another reason",
         "the displaced item keeps the sentence recording its own last mark")
end

function T.what_it_was_given_is_not_mutated()
  local entries = { "a", { text = "b", state = "done" } }
  local second = entries[2]
  local plan = assert(work.plan(entries))
  assert(#entries == 2 and entries[1] == "a" and entries[2] == second)
  assert(second.id == nil, "an id was minted into the plan, not into the caller's table")
  assert(plan.items[2] ~= second, "the entry is copied, not retained")
  second.text = "b, rewritten behind its back"
  assert(plan.items[2].text == "b")

  local paths = { "b.txt", "a.txt", "b.txt" }
  local port = world { ["a.txt"] = "A", ["b.txt"] = "B" }
  local cp = assert(work.take(port, paths))
  assert(#paths == 3 and paths[1] == "b.txt" and paths[2] == "a.txt",
         "the caller's list is copied before it is sorted, never reordered in place")
  assert(cp.files[1].path == "a.txt" and cp.count == 2)

  -- And undo writes nothing into the checkpoint, so the same one undoes twice.
  local before = cp.files[1].text
  work.undo(port, cp)
  assert(cp.id == nil and cp.files[1].text == before and cp.count == 2)
end

return T
