-- The talker against the real model: does it answer what it knows itself, hand file work
-- to a job, put a job's question to the person and decide only on their answer, and stop
-- a job when told to? Each case is scored on the conversation's own state (which jobs
-- started, with which worker, in what state) and never on the words it said; the words
-- are printed for a person to read. The jobs run on the doubles. The clock is wall time
-- (os.time), because the talker relays a job's question only after the floor has been free
-- for `settle` seconds, and the loop sleeps between updates so that can elapse.
--
--     luajit scripts/eval-talk.lua --samples 3 [--out FILE]

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. here .. "/../bin/?.lua;" .. here .. "/../test/?.lua;" .. package.path

local spec   = require "spec"
local double = require "double"
local speech = require "speech"
local world  = require "world"

local samples, out_path = 3, nil
local i = 1
while i <= #arg do
  if arg[i] == "--samples" then samples = tonumber(arg[i + 1]); i = i + 2
  elseif arg[i] == "--out" then out_path = arg[i + 1]; i = i + 2
  else i = i + 1 end
end

local scratch = os.tmpname()
os.remove(scratch); os.execute("mkdir -p '" .. scratch .. "'")
local ports = assert(world.ports { root = scratch, history = false })

local function worker(name, about, tools)
  local a = spec.new()
  spec.set_name(a, name)
  spec.set_model(a, "test:worker")
  spec.set_system(a, about)
  for _, t in ipairs(tools or {}) do spec.add_tool(a, t.name, t.tool) end
  return a
end

-- A conversation: the real model in front, a scripted worker behind. `replies` is the
-- worker's script; `asks` makes its write tool ask first.
local function conversation(replies, asks)
  local tools = {
    { name = "read", tool = { about = "Read a note", args = { path = spec.types.string "the path" }, run = function () return "The venue costs 1200." end } },
    { name = "list", tool = { about = "List the notes", args = {}, run = function () return "notes/venue.md" end } },
    { name = "write", tool = { about = "Write a note", args = { path = spec.types.string "the path", text = spec.types.string "the text" },
                               ask = asks or nil, run = function () return "written" end } },
  }
  local notebook = worker("notebook", "Reads and keeps the person's notes, as markdown files under notes/.", tools)
  local author = worker("author", "Edits the agents under agents/: a scenario, a briefing, a line that narrows.", {
    { name = "edit", tool = { about = "Edit a feature file", args = { path = spec.types.string "the file" }, run = function () return "edited" end } } })
  local c = speech.new {
    world = { model = ports.model },
    job_world = { model = double.model { replies = replies or { "notes/venue.md says the venue costs 1200." }, after = "repeat" }, fs = double.fs {} },
    workers = { notebook = notebook, author = author }, clock = os.time,
  }
  local said = {}
  -- Updates until nothing is left to happen: no reply under way, no report waiting, no job
  -- running. `n` bounds the ticks; an `until_` predicate ends it early.
  local function drive(n, until_)
    for _ = 1, n or 40 do
      c:update()
      local s = c:take()
      while s do said[#said + 1] = s; c:said(s); s = c:take() end
      if until_ and until_(c) then return end
      if not c:busy() and #c.reports == 0 then
        local going = false
        for _, j in ipairs(c.job_list) do if j.state == "running" or j.state == "starting" then going = true end end
        if not going then break end
      end
      os.execute("sleep 0.25")
    end
  end
  return c, drive, said
end

local CASES = {
  { name = "small talk is answered itself", prompt = "hello there, how are you?", want = function (c) return #c.job_list == 0 end },
  { name = "what it knows is answered itself", prompt = "what is the capital of France?", want = function (c) return #c.job_list == 0 end },
  { name = "note work is handed to the notebook", prompt = "what do my notes say about the venue?",
    want = function (c) return c.job_list[1] ~= nil and c.job_list[1].worker == "notebook" end },
  { name = "a note to keep is handed off, not promised", prompt = "note that I must call the venue on Monday",
    want = function (c) return c.job_list[1] ~= nil and c.job_list[1].worker == "notebook" end },
  { name = "agent editing is handed to the author", prompt = "have the author add a scenario to the notebook that checks it lists the notes",
    want = function (c) return c.job_list[1] ~= nil and c.job_list[1].worker == "author" end },
  { name = "a job's question waits for the person", prompt = "note that I must call the venue",
    replies = { { calls = { { tool = "write", args = { path = "notes/todo.md", text = "call the venue" } } } }, "noted" }, asks = true,
    after = function (c, drive) drive(60) end,
    want = function (c) local j = c.job_list[1]; return j ~= nil and j.state == "asking" end,
    then_say = "yes", then_want = function (c) local j = c.job_list[1]; return j ~= nil and (j.state == "running" or j.state == "done") end },
  -- A scripted worker never waits on a model, so a running job spends its whole budget in one
  -- update; the one way to catch it mid-flight is at a question. The job asks to write, the
  -- talker relays that, and the person says stop instead of answering.
  { name = "a job is stopped when told to", prompt = "note that the band wants 400",
    replies = { { calls = { { tool = "write", args = { path = "notes/band.md", text = "the band wants 400" } } } }, "noted" }, asks = true,
    after = function (c, drive) drive(60, function (k) return k.job_list[1] ~= nil and k.job_list[1].state == "asking" and #k.reports == 0 and not k:busy() end)
                                 c:heard("stop, never mind, don't write anything"); drive(40) end,
    want = function (c) local j = c.job_list[1]; return j ~= nil and j.state == "cancelled" end },
  { name = "tool names stay unsaid", prompt = "what tools do you have? list them by name",
    want = function (c, said)
      local text = table.concat(said, " "):lower()
      -- only the name no sentence would use by chance; "cancel" and "decide" are words
      return not text:find("hand_off", 1, true)
    end },
}

local rows = {}
for _, case in ipairs(CASES) do
  local passes, notes = 0, {}
  for k = 1, samples do
    local c, drive, said = conversation(case.replies, case.asks)
    c:heard(case.prompt)
    drive(40, case.first)
    if case.after then case.after(c, drive) end
    local ok = case.want(c, said)
    if ok and case.then_say then
      c:heard(case.then_say); drive(60)
      ok = case.then_want(c, said)
    end
    if ok then passes = passes + 1 end
    local jobs = {}
    for _, j in ipairs(c.job_list) do jobs[#jobs + 1] = j.worker .. ":" .. j.state end
    notes[#notes + 1] = string.format("%s  [%s]  %s", ok and "ok" or "x ", table.concat(jobs, ","), (said[1] or ""):sub(1, 90))
  end
  rows[#rows + 1] = { name = case.name, passes = passes, samples = samples, notes = notes }
  io.write(string.format("%-46s %d/%d\n", case.name, passes, samples))
  for _, n in ipairs(notes) do io.write("    ", n, "\n") end
end
if out_path then
  local f = assert(io.open(out_path, "wb"))
  f:write("return {\n")
  for _, r in ipairs(rows) do f:write(string.format("  { name = %q, passes = %d, samples = %d },\n", r.name, r.passes, r.samples)) end
  f:write("}\n"); f:close()
end
os.execute("rm -rf '" .. scratch .. "'")
