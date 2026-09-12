-- speech -- a talker in front, jobs behind (spec/speech.md).
--
--     local c = speech.new { workers = { research = research_agent }, world = port }
--     c.on = function (event, data) ... end
--     c:heard("what's in my notes about the budget?")
--     while c:busy() do c:update(); local s = c:take(); if s then say(s); c:said(s) end end
--
-- The talker is a small, fast agent that holds the conversation; everything that needs
-- work it hands to a job, an ordinary run of a worker agent in the background, whose report
-- comes back to the talker to tell. A reply and every job is a coroutine, resumed by
-- `update` when what it waits for is over, so a job's slow model call sits in the
-- background while the talker answers the next turn. Nothing here touches the world but
-- through the ports it was handed.

local spec    = require "spec"
local turn    = require "turn"
local declare = require "declare"
local wait    = require "wait"
local history = require "history"

local speech = {}

speech.MODEL     = "openrouter:z-ai/glm-5.3"
speech.REASONING = "low"
speech.BUDGET    = 3

speech.BRIEF = [[You are the voice of a team of agents, in a spoken conversation: the person speaks, and hears what you say.

- Keep every reply short: one spoken sentence, two if you need them. Longer only when asked.
- Speak plainly. No markdown, lists, headings, symbols or emoji.
- What you hear is a transcript and may be misheard. If the meaning is unclear, ask.
- Answer small talk, and what you already know, yourself.
- Anything that needs work (reading or writing files, looking something up, several steps, anything you are not sure of) you hand to a job with hand_off. In the same reply, first say a short lead-in, such as "Let me look into that." The task you hand off is all the job knows: it does not hear this conversation.
- A job works in the background, and the person can go on talking to you meanwhile. Never say its work is done before its report comes to you.
- When a report comes, tell the person what it found, briefly and in your own words, keeping names and numbers exact. If several came, give each a sentence.
- When a job asks for permission, put its question to the person in one sentence. Call decide only with the person's answer, never on your own.
- To say how the jobs are going, call jobs. To stop one, call cancel.
- Never say the name of a tool.]]

local KEYS = {
  workers = true, world = true, talker = true, job_world = true, run = true, clock = true,
  keep = true, jobs = true, job_budget = true, proactive = true, settle = true, relay = true,
}

local ANSWER_CAP = 2000

local function fail(fmt, ...) error("speech: " .. string.format(fmt, ...), 3) end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function emit(c, event, data)
  if type(c.on) == "function" then pcall(c.on, event, data) end
end

-- Text over `cap` keeps its first part and its end: a conclusion is usually last.
local function capped(text, cap)
  if #text <= cap then return text end
  local head = math.ceil(cap * 0.6)
  local tail = cap - head
  return text:sub(1, head) .. "\n(" .. (#text - cap) .. " characters left out)\n" .. text:sub(-tail)
end

-- A value, compact and deterministic, for a question about a call's arguments.
local function render(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "string" then return string.format("%q", #v > 120 and (v:sub(1, 117) .. "...") or v) end
  if t ~= "table" then return tostring(v) end
  if depth > 2 then return "{...}" end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for i = 1, #keys do
    parts[#parts + 1] = tostring(keys[i]) .. " = " .. render(v[keys[i]], depth + 1)
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

-- ------------------------------------------------------------------ sentences

-- What a voice can say of a piece of text: markdown's marks and list bullets out, links to
-- their words, the characters no voice says out, the spaces collapsed. The history keeps
-- the text as written; only what goes to the mouth is narrowed.
local function speakable(s)
  s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")               -- [words](link) -> words
  s = s:gsub("\n[ \t]*[%-%*+][ \t]+", "\n")                -- bullets
  s = s:gsub("^[ \t]*[%-%*+][ \t]+", "")
  s = s:gsub("\n[ \t]*#+[ \t]*", "\n")                     -- headings
  s = s:gsub("^[ \t]*#+[ \t]*", "")
  s = s:gsub("[%*`#|~<>{}%[%]\\^]", "")
  s = s:gsub("[%c]", " ")
  s = s:gsub("%s+", " ")
  return (s:gsub("^ ", ""):gsub(" $", ""))
end

--- The sentences of `text` a voice can start saying, and the rest, which is not yet a
--- sentence. A sentence ends at a stop, a question or exclamation mark followed by a space,
--- a quote or a bracket, or at a line break. With `whole`, the text is all there is and
--- the rest is a sentence too.
function speech.sentences(text, whole)
  local out = {}
  text = type(text) == "string" and text or ""
  while true do
    local stop = text:find("[%.%!%?][%s\"')]", 1)
    local line = text:find("\n", 1, true)
    if line and (not stop or line < stop) then stop = line end
    if not stop then break end
    local s = speakable(text:sub(1, stop))
    if s:match("%w") then out[#out + 1] = s end
    text = text:sub(stop + 1)
  end
  if whole then
    local s = speakable(text)
    if s:match("%w") then out[#out + 1] = s end
    text = ""
  end
  return out, text
end

-- ------------------------------------------------------------------ the talker

--- The default talker: a declaration with the brief and no tools. `speech.new` adds its
--- four tools to a copy. opts: model, reasoning, budget, brief, name.
function speech.talker(opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("speech.talker takes a table of options or nothing") end
  for k in pairs(opts) do
    if not (k == "model" or k == "reasoning" or k == "budget" or k == "brief" or k == "name") then
      fail("speech.talker has no option %q", tostring(k))
    end
  end
  local a = spec.new()
  spec.set_name(a, opts.name or "talker")
  spec.set_model(a, opts.model or speech.MODEL)
  spec.set_reasoning(a, opts.reasoning or speech.REASONING)
  spec.set_budget(a, opts.budget or speech.BUDGET)
  spec.set_system(a, opts.brief or speech.BRIEF)
  return a
end

-- A copy of a declaration that can take tools without the original gaining any.
local function declaration_copy(d)
  local out = {}
  for k, v in pairs(d) do out[k] = v end
  out.tools, out.order = {}, {}
  for k, v in pairs(d.tools or {}) do out.tools[k] = v end
  for i = 1, #(d.order or {}) do out.order[i] = d.order[i] end
  return out
end

local function first_line(s)
  if type(s) ~= "string" then return nil end
  local line = s:match("^%s*([^\n]+)")
  if not line then return nil end
  return #line > 160 and (line:sub(1, 157) .. "...") or line
end

-- ------------------------------------------------------------------ runs and waits

-- A run is a coroutine and what it waits for. `stack` is its own stack of delegate worlds
-- (declare.swap), so a delegate inside one run never reads another's.
local function new_run(fn)
  return { co = coroutine.create(fn), wait = nil, stack = {} }
end

local function abandon(r)
  if r then wait.cancel(r.wait) end
  if r then r.wait, r.abandoned = nil, true end
end

local function now(c) return c.clock and c.clock() or nil end

-- Resumes `r` if what it waits for is over. Answers "waiting", "paused" (it yielded again),
-- "ended" and the run's result, or "raised" and the error.
local function step(c, r, on_person)
  local w, value = r.wait, nil
  if w then
    local status, v = wait.ready(w, { now = now(c), wake = r.wake, decision = r.decision })
    if status == "waiting" then return "waiting" end
    if status == "raised" then r.wait = nil; return "raised", v end
    if wait.kind(w) == wait.PERSON then r.decision = nil end
    value = v
  end
  r.wait = nil
  local outer = declare.swap(r.stack)
  local ok, got = coroutine.resume(r.co, value)
  r.stack = declare.swap(outer)
  if not ok then return "raised", tostring(got) end
  if coroutine.status(r.co) == "dead" then return "ended", got end
  r.wait = type(got) == "table" and got or {}
  local kind = wait.kind(r.wait)
  if kind == wait.SLEEP then
    r.wake = wait.wake(r.wait, now(c))
  elseif kind == wait.PERSON and on_person then
    on_person(r.wait.question)
  end
  return "paused"
end

-- ------------------------------------------------------------------ the conversation

local C = {}
C.__index = C

local function floor_free(c)
  return not c.person_speaking and c.reply == nil and #c.out == 0 and c.saying == nil
end

local function running_jobs(c)
  local n = 0
  for i = 1, #c.job_list do
    local s = c.job_list[i].state
    if s == "starting" or s == "running" or s == "asking" then n = n + 1 end
  end
  return n
end

-- The history the talker is given: the last `keep` messages, starting at a user message,
-- so a call is never separated from its result.
local function history_for(c)
  local h = c.history
  local from = math.max(1, #h - c.keep + 1)
  while from <= #h and h[from].role ~= "user" do from = from + 1 end
  local out = {}
  for i = from, #h do out[#out + 1] = copy(h[i]) end
  return out
end

local function reports_text(c)
  local lines = { "(From your jobs. These are not the person's words.)" }
  for i = 1, #c.reports do lines[#lines + 1] = c.reports[i].text end
  return table.concat(lines, "\n")
end

-- The messages a reply added, as far as they happened: the last request's messages past
-- the history it was given, and the last reply if nothing asked after it.
local function messages_so_far(r)
  local out = {}
  if r.request and type(r.request.messages) == "table" then
    for i = #r.given + 1, #r.request.messages do out[#out + 1] = copy(r.request.messages[i]) end
  else
    out[1] = { role = "user", text = r.prompt }
  end
  if not r.pending and r.last and type(r.last.text) == "string"
     and not (type(r.last.calls) == "table" and #r.last.calls > 0) then
    out[#out + 1] = { role = "agent", text = r.last.text }
  end
  return out
end

-- A cut reply is remembered as far as it was said: each of its texts keeps the sentences
-- that were handed to the mouth, the one being said included.
local function cut_texts(c, r, messages)
  local k = 0
  for i = 1, #messages do
    local m = messages[i]
    if m.role == "agent" then
      k = k + 1
      local st = r.steps[k]
      if st then
        local kept = {}
        for j = 1, #st.pieces do
          local p = st.pieces[j]
          if p.said or p == c.saying then kept[#kept + 1] = p.text end
        end
        m.text = table.concat(kept, " ")
      end
    end
  end
  return messages
end

local function reply_settled(c, r)
  if not r.ended then return end
  for i = 1, #c.out do if c.out[i].reply == r then return end end
  if c.saying and c.saying.reply == r then return end
  if r.announced then return end
  r.announced = true
  emit(c, "done", { stop = r.result and r.result.stop or "error", steps = r.result and r.result.steps or 0 })
end

local function finish_reply(c, r, result)
  r.ended, r.result = true, result
  if c.reply == r then c.reply = nil end
  local new = {}
  if type(result) == "table" and type(result.transcript) == "table" then
    local skip = #r.given
    for i = 1, #result.transcript do
      local m = result.transcript[i]
      if m.role ~= "system" then
        if skip > 0 then skip = skip - 1 else new[#new + 1] = copy(m) end
      end
    end
  else
    new[1] = { role = "user", text = r.prompt }
  end
  r.from = #c.history + 1
  for i = 1, #new do c.history[#c.history + 1] = new[i] end
  if type(result) ~= "table" or result.stop == "error" then
    local why = type(result) == "table" and result.reason or tostring(result)
    emit(c, "failed", { reason = why })
  end
  reply_settled(c, r)
end

-- The talker's model, wrapped: what it writes goes to the mouth as it comes back from each
-- call, before any tool in the same reply runs, so a lead-in is heard first.
local function talker_port(c, r)
  local base = c.world
  local p = {}
  for k, v in pairs(base) do p[k] = v end
  local m = base.model
  local function call(request)
    if type(m) == "function" then return m(request) end
    return m.call(request)
  end
  p.model = { call = function (request)
    r.request, r.pending = request, true
    local reply, err = call(request)
    r.pending, r.last = false, reply
    if r.abandoned then return reply, err end
    local text = type(reply) == "table" and reply.text or nil
    local st = { pieces = {} }
    r.steps[#r.steps + 1] = st
    if type(text) == "string" and text:match("%S") then
      local sentences = speech.sentences(text, true)
      for i = 1, #sentences do
        local piece = { text = sentences[i], reply = r }
        st.pieces[#st.pieces + 1] = piece
        c.out[#c.out + 1] = piece
      end
      emit(c, "reply", { text = text })
    end
    return reply, err
  end }
  return p
end

local function start_reply(c, prompt, kind)
  local given = history_for(c)
  local r = { kind = kind, prompt = prompt, given = given, steps = {} }
  local port = talker_port(c, r)
  local run = new_run(function ()
    -- Kept as a `talk` entry when the world keeps a history; the id is known at once, so a
    -- job this reply starts can name it (docs/spec/history.md).
    -- The tap's log is held as the run goes, so a screen can draw it before it is kept, and
    -- what a look at the history found is told (spec/home.md).
    return c.run(c.talker, prompt, port, { history = given, id = c.talker.name,
      entry = { cause = "talk", from = kind == "report" and "jobs" or "person",
                claimed = function (id, log, at) r.entry, r.log, r.started = id, log, at end,
                found = function (q, ids) emit(c, "found", { query = q, ids = ids, by = "talker" }) end } })
  end)
  for k, v in pairs(run) do r[k] = v end
  c.reply = r
  c.free_at = nil
  return r
end

--- Cuts the reply the person spoke over: its run is abandoned, the sentences still waiting
--- are dropped, and the history keeps it as far as it was said. A job it started stays.
function C:cut()
  local c = self
  local r = c.reply
  if r == nil then
    -- a reply that ended and is still being said
    for i = #c.out, 1, -1 do if c.out[i].reply then r = c.out[i].reply; break end end
    if r == nil and c.saying then r = c.saying.reply end
  end
  if r == nil then return end
  local kept = {}
  if not r.ended then
    abandon(r)
    c.reply = nil
    local messages = cut_texts(c, r, messages_so_far(r))
    r.from = #c.history + 1
    for i = 1, #messages do c.history[#c.history + 1] = messages[i] end
    r.ended, r.result = true, { stop = "cut", steps = #r.steps }
  else
    local messages = {}
    for i = r.from, #c.history do messages[#messages + 1] = c.history[i] end
    cut_texts(c, r, messages)
  end
  for i = 1, #r.steps do
    for j = 1, #r.steps[i].pieces do
      local p = r.steps[i].pieces[j]
      if p.said or p == c.saying then kept[#kept + 1] = p.text end
    end
  end
  local left = {}
  for i = 1, #c.out do if c.out[i].reply ~= r then left[#left + 1] = c.out[i] end end
  c.out = left
  if c.saying and c.saying.reply == r then c.saying = nil end
  r.announced = true
  emit(c, "cut", { said = table.concat(kept, " ") })
end

--- The person's turn ended with these words. Empty words are a noise: the person has only
--- stopped speaking.
function C:heard(text)
  local c = self
  c.person_speaking = false
  if type(text) ~= "string" or not text:match("%S") then return end
  if c.reply or #c.out > 0 or c.saying then c:cut() end
  c.turns = c.turns + 1
  c.last_heard = text
  local prompt = text
  if not c.proactive and #c.reports > 0 then
    prompt = reports_text(c) .. "\n\n" .. text
    c.reports = {}
  end
  start_reply(c, prompt, "turn")
end

--- The person started speaking: reports wait. It does not cut; the host decides that.
function C:hearing()
  self.person_speaking = true
  self.free_at = nil
end

--- The next sentence to say, or nil.
function C:take()
  local c = self
  if c.saying then return nil end
  local piece = table.remove(c.out, 1)
  if not piece then return nil end
  c.saying = piece
  return piece.text
end

--- The mouth finished saying the sentence `take` handed out.
function C:said()
  local c = self
  local piece = c.saying
  if not piece then return end
  piece.said = true
  c.saying = nil
  reply_settled(c, piece.reply)
end

function C:busy()
  return self.reply ~= nil or #self.out > 0 or self.saying ~= nil
end

--- Something is waiting to be said, or being said: the mouth holds the floor between one
--- sentence and the next, not only while one plays.
function C:pending()
  return #self.out > 0 or self.saying ~= nil
end

local function start_report_reply(c)
  local prompt = reports_text(c)
  local ids = {}
  for i = 1, #c.reports do ids[#ids + 1] = c.reports[i].job end
  c.reports = {}
  start_reply(c, prompt, "report")
  emit(c, "report", { ids = ids })
  return true
end

--- Speaks the reports waiting now, if the floor is free. True if a reply started.
function C:deliver()
  local c = self
  if #c.reports == 0 or not floor_free(c) then return false end
  return start_report_reply(c)
end

-- ------------------------------------------------------------------ jobs

local function job_event(c, job)
  emit(c, "job", { id = job.id, worker = job.worker, state = job.state, steps = job.steps,
                   entry = job.entry, parent = job.parent })
end

local function report(c, job, kind, text)
  c.reports[#c.reports + 1] = { job = job.id, kind = kind, text = text }
end

local function drop_question(c, job)
  local left = {}
  for i = 1, #c.reports do
    local r = c.reports[i]
    if not (r.job == job.id and r.kind == "question") then left[#left + 1] = r end
  end
  c.reports = left
end

local function end_job(c, job, result)
  local stop = type(result) == "table" and result.stop or "error"
  job.result = result
  job.ended = now(c) or 0     -- seconds on the host clock, when there is one
  local head = job.id .. ", " .. job.worker .. ", "
  if stop == "answered" then
    job.state = "done"
    local answer = type(result.answer) == "string" and result.answer or ""
    report(c, job, "end", head .. "done in " .. (result.steps or 0) .. " steps: "
      .. (answer:match("%S") and capped(answer, ANSWER_CAP) or "it answered with no text."))
  elseif stop == "budget" then
    job.state = "spent"
    local last = ""
    for i = #(result.transcript or {}), 1, -1 do
      local m = result.transcript[i]
      if m.role == "agent" and type(m.text) == "string" and m.text:match("%S") then last = m.text; break end
    end
    report(c, job, "end", head .. "ran out of its " .. (result.budget or c.job_budget)
      .. " steps without finishing." .. (last ~= "" and (" Its last words: " .. capped(last, ANSWER_CAP)) or ""))
  elseif stop == "refused" then
    job.state = "refused"
    report(c, job, "end", head .. "was stopped: " .. tostring(result.reason))
  else
    job.state = "failed"
    local why = type(result) == "table" and (result.reason or (result.err and result.err.message)) or tostring(result)
    report(c, job, "end", head .. "failed: " .. tostring(why))
  end
  job_event(c, job)
end

-- The job's world: the host's, with its model counted and, when relaying, its gate put to
-- the person through the talker.
local function job_port(c, job)
  local base = c.job_world
  if type(base) == "function" then
    local ok, got, why = pcall(base, { id = job.id, worker = job.worker, task = job.task })
    if not ok then return nil, tostring(got) end
    if type(got) ~= "table" then return nil, tostring(why or "no world for the job") end
    base = got
  end
  local p = {}
  for k, v in pairs(base) do p[k] = v end
  local m = base.model
  if m ~= nil then
    p.model = { call = function (request)
      job.steps = job.steps + 1
      local msgs = type(request) == "table" and request.messages or {}
      for i = #msgs, 1, -1 do
        local x = msgs[i]
        if x.role == "agent" and type(x.calls) == "table" and #x.calls > 0 then
          local names = {}
          for j = 1, #x.calls do names[#names + 1] = tostring(x.calls[j].tool) end
          job.doing = table.concat(names, ", ")
          break
        end
      end
      -- the calls made so far, in the shape a run's result holds them, so the job can be
      -- observed while it runs (docs/spec/agent-file.md): each agent message's calls, and
      -- the tool messages that answered them
      local calls, by_id, step = {}, {}, 0
      for i = 1, #msgs do
        local x = msgs[i]
        if x.role == "agent" then
          step = step + 1
          for j = 1, #(type(x.calls) == "table" and x.calls or {}) do
            local k = x.calls[j]
            local rec = { id = k.id, tool = tostring(k.tool), args = k.args, step = step }
            calls[#calls + 1] = rec
            if k.id ~= nil then by_id[k.id] = rec end
          end
        elseif x.role == "tool" then
          local rec = x.id ~= nil and by_id[x.id] or nil
          if rec then rec.ok, rec.refused = x.ok, x.refused end
        end
      end
      job.calls = calls
      if type(m) == "function" then return m(request) end
      return m.call(request)
    end }
  end
  if c.relay then
    p.ask = { request = function (q)
      if not (coroutine.isyieldable and coroutine.isyieldable()) then
        return { allow = false, why = "there is no one to ask" }
      end
      return coroutine.yield(wait.person(q))
    end }
  end
  return p
end

local function start_job(c, job)
  local decl = c.workers[job.worker]
  local port, why = job_port(c, job)
  if not port then
    end_job(c, job, { stop = "error", reason = "the job was given no world: " .. tostring(why) })
    return
  end
  -- the job's own trace, live: a host reads its spans while it runs, and the runs it
  -- delegates hang under them when they end (docs/spec/agent-file.md)
  job.tracer = turn.recorder(port.clock, port.log, 1)
  job.run = new_run(function ()
    return c.run(decl, job.task, port, { budget = c.job_budget, depth = 1, id = job.id, tracer = job.tracer,
      entry = { cause = "job", from = "talker", parent = job.parent,
                claimed = function (id, log, at) job.entry, job.log, job.started = id, log, at end,
                found = function (q, ids) emit(c, "found", { query = q, ids = ids, by = job.id }) end } })
  end)
  job.state = "running"
  job_event(c, job)
end

local function step_job(c, job)
  if job.state == "starting" then start_job(c, job) end
  if not (job.state == "running" or job.state == "asking") then return end
  local status, got = step(c, job.run, function (q)
    job.state = "asking"
    job.question = q
    job.asked_turn = c.turns
    local tool = type(q) == "table" and tostring(q.tool) or "a tool"
    local about = type(q) == "table" and type(q.about) == "string" and q.about or ""
    local args = type(q) == "table" and q.args ~= nil and (" with " .. render(q.args)) or ""
    report(c, job, "question", job.id .. ", " .. job.worker .. ", asks to run " .. tool
      .. (about ~= "" and (" (" .. about .. ")") or "") .. args
      .. ". Ask the person, and call decide with their answer.")
    job_event(c, job)
    emit(c, "question", { id = job.id, tool = tool })
  end)
  if status == "ended" then
    end_job(c, job, got)
  elseif status == "raised" then
    end_job(c, job, { stop = "error", reason = "its run raised: " .. tostring(got) })
  end
end

local function find_job(c, id)
  if type(id) ~= "string" then return nil, "a job is named by its id, like j1" end
  local job = c.by_id[id]
  if not job then
    local ids = {}
    for i = 1, #c.job_list do ids[#ids + 1] = c.job_list[i].id end
    return nil, "there is no job " .. id .. (#ids > 0 and ("; the jobs are " .. table.concat(ids, ", ")) or "; no job has been started")
  end
  return job
end

local function decide(c, id, allow, why, by_talker)
  local job, err = find_job(c, id)
  if not job then return nil, err end
  if job.state ~= "asking" then return nil, job.id .. " is not asking anything; it is " .. job.state end
  if by_talker and c.turns <= (job.asked_turn or 0) then
    return nil, "the person has not answered yet: put the question to them, and decide after they speak"
  end
  if type(allow) ~= "boolean" then return nil, "allow is true or false" end
  local said = c.last_heard and ("the person said: " .. c.last_heard) or nil
  job.run.decision = { allow = allow, why = why or said }
  job.state, job.question = "running", nil
  drop_question(c, job)
  job_event(c, job)
  return true
end

local function cancel(c, id, quiet)
  local job, err = find_job(c, id)
  if not job then return nil, err end
  if not (job.state == "starting" or job.state == "running" or job.state == "asking") then
    return nil, job.id .. " is not running; it is " .. job.state
  end
  abandon(job.run)
  job.state = "cancelled"
  drop_question(c, job)
  if not quiet then report(c, job, "end", job.id .. ", " .. job.worker .. ", was cancelled.") end
  job_event(c, job)
  return true
end

function C:decide(id, allow, why) return decide(self, id, allow, why, false) end
function C:cancel(id) return cancel(self, id, false) end

function C:jobs()
  local out = {}
  for i = 1, #self.job_list do
    local j = self.job_list[i]
    out[i] = { id = j.id, worker = j.worker, task = j.task, state = j.state, steps = j.steps,
               entry = j.entry, parent = j.parent, log = j.log, started = j.started,
               calls = j.calls, result = j.result, question = j.question, ended = j.ended,
               spans = j.tracer and j.tracer.spans or nil }
  end
  return out
end

-- The four tools the talker holds. Each is a closure over this conversation.
local function talker_tools(c)
  local roster = c.roster
  local to
  if #roster > 1 then
    to = spec.types.one_of_opt("which worker does it: " .. table.concat(roster, ", "))(roster)
  else
    to = spec.types.string_opt("the worker; there is one, " .. roster[1])
  end
  return {
    hand_off = {
      about = "Start a job: a worker does a task in the background while you go on talking. "
        .. "In the same reply, before this call, always say a short lead-in to the person, such as "
        .. "\"Let me look into that.\": they hear nothing else from you until the job reports. "
        .. "The job does not hear this conversation, so the task must say everything it needs.",
      args = { task = spec.types.string "everything the job needs to know to do the work", to = to },
      ends = true,
      effect = "starts",
      run = function (ctx)
        local task = ctx.args.task
        if type(task) ~= "string" or not task:match("%S") then return nil, "the task is empty: say what the job is to do" end
        local worker = ctx.args.to or roster[1]
        if #roster > 1 and ctx.args.to == nil then
          return nil, "say which worker: " .. table.concat(roster, ", ")
        end
        if not c.workers[worker] then
          return nil, "there is no worker " .. tostring(worker) .. "; the workers are " .. table.concat(roster, ", ")
        end
        if running_jobs(c) >= c.max_jobs then
          return nil, "there are already " .. c.max_jobs .. " jobs running, the most at once; wait for one, or cancel one"
        end
        c.seq = c.seq + 1
        local job = { id = "j" .. c.seq, worker = worker, task = task, state = "starting", steps = 0,
                      parent = c.reply and c.reply.entry }
        c.by_id[job.id] = job
        c.job_list[#c.job_list + 1] = job
        job_event(c, job)
        return "Started " .. job.id .. ": " .. worker .. " is working on it. Its report will come to you when it ends."
      end,
    },
    jobs = {
      about = "How the jobs are going: each job, its worker, its task, its state and its steps so far.",
      args = {},
      run = function ()
        if #c.job_list == 0 then return "No job has been started." end
        local lines = {}
        for i = 1, #c.job_list do
          local j = c.job_list[i]
          local task = #j.task > 100 and (j.task:sub(1, 97) .. "...") or j.task
          lines[#lines + 1] = j.id .. ", " .. j.worker .. ": " .. j.state .. ", " .. j.steps .. " steps"
            .. (j.doing and j.state == "running" and (", last used " .. j.doing) or "")
            .. ". Task: " .. task
        end
        return table.concat(lines, "\n")
      end,
    },
    cancel = {
      about = "Stop a job that is running. Say so to the person in the same reply.",
      args = { job = spec.types.string "the job's id, like j1" },
      ends = true,
      run = function (ctx)
        local ok, why = cancel(c, ctx.args.job, true)
        if not ok then return nil, why end
        return ctx.args.job .. " is stopped."
      end,
    },
    decide = {
      about = "Answer a job that asked for permission, with what the person said. Only after the person "
        .. "has answered. In the same reply, say what happens now, such as \"Okay, it's going ahead.\"",
      args = {
        job = spec.types.string "the job's id, like j1",
        allow = spec.types.boolean "true if the person said yes",
        why = spec.types.string_opt "the person's words, briefly",
      },
      ends = true,
      run = function (ctx)
        local ok, why = decide(c, ctx.args.job, ctx.args.allow, ctx.args.why, true)
        if not ok then return nil, why end
        return ctx.args.job .. " has the person's answer."
      end,
    },
  }
end

--- One slice: the reply first, then every job, then a report if the floor is free.
function C:update()
  local c = self
  local r = c.reply
  if r then
    local status, got = step(c, r)
    if status == "ended" then finish_reply(c, r, got)
    elseif status == "raised" then finish_reply(c, r, { stop = "error", reason = "the reply raised: " .. tostring(got) }) end
  end
  for i = 1, #c.job_list do step_job(c, c.job_list[i]) end
  if c.proactive and #c.reports > 0 and floor_free(c) then
    local t = now(c)
    if t and c.free_at == nil then c.free_at = t end
    if t == nil or t - c.free_at >= c.settle then start_report_reply(c) end
  elseif not floor_free(c) then
    c.free_at = nil
  end
end

-- ------------------------------------------------------------------ building

local function whole(v, low) return type(v) == "number" and v >= low and v == math.floor(v) end

--- A conversation. See spec/speech.md for cfg.
function speech.new(cfg)
  if type(cfg) ~= "table" then fail("speech.new takes a table") end
  for k in pairs(cfg) do
    if not KEYS[k] then fail("speech.new has no option %q", tostring(k)) end
  end
  if type(cfg.world) ~= "table" or cfg.world.model == nil then
    fail("speech.new needs `world`, a port with a model for the talker")
  end
  local workers = cfg.workers
  if type(workers) == "table" and type(workers.tools) == "table" then
    if type(workers.name) ~= "string" then fail("a worker declaration needs a name") end
    workers = { [workers.name] = workers }
  end
  if type(workers) ~= "table" or next(workers) == nil then
    fail("speech.new needs `workers`: a table of name to declaration, or one declaration")
  end
  local roster = {}
  for name, d in pairs(workers) do
    if type(name) ~= "string" or name == "" or type(d) ~= "table" then
      fail("`workers` maps a name to a declaration")
    end
    roster[#roster + 1] = name
  end
  table.sort(roster)
  for _, key in ipairs { "keep", "jobs", "job_budget" } do
    if cfg[key] ~= nil and not whole(cfg[key], 1) then fail("`%s` is a whole number, at least 1", key) end
  end
  if cfg.settle ~= nil and (type(cfg.settle) ~= "number" or cfg.settle < 0) then
    fail("`settle` is a number of seconds, 0 or more")
  end
  if cfg.clock ~= nil and type(cfg.clock) ~= "function" then fail("`clock` is a function answering seconds") end
  if cfg.run ~= nil and type(cfg.run) ~= "function" then fail("`run` is a function (decl, prompt, port, opts)") end
  if cfg.job_world ~= nil and type(cfg.job_world) ~= "table" and type(cfg.job_world) ~= "function" then
    fail("`job_world` is a port, or a function (job) -> port")
  end

  local base = cfg.talker
  if base == nil or (type(base) == "table" and base.tools == nil) then base = speech.talker(base) end
  if type(base) ~= "table" or type(base.tools) ~= "table" then fail("`talker` is a declaration, or options for the default one") end

  local c = setmetatable({
    world = cfg.world, workers = workers, roster = roster,
    job_world = cfg.job_world or cfg.world,
    run = history.keeper(cfg.run or turn.run), clock = cfg.clock,
    keep = cfg.keep or 40, max_jobs = cfg.jobs or 4, job_budget = cfg.job_budget or 24,
    proactive = cfg.proactive ~= false, settle = cfg.settle or 0.6, relay = cfg.relay ~= false,
    history = {}, turns = 0, person_speaking = false, reply = nil, out = {}, saying = nil,
    by_id = {}, job_list = {}, seq = 0, reports = {}, free_at = nil,
    on = function () end,
  }, C)

  local talker = declaration_copy(base)
  local tools = talker_tools(c)
  for _, name in ipairs { "hand_off", "jobs", "cancel", "decide" } do
    if talker.tools[name] then fail("the talker declares a tool %q, which is the conversation's own", name) end
    spec.add_tool(talker, name, tools[name])
  end
  -- With a history, the talker can say what was done before at once, from the listing; the
  -- story and the evidence behind an entry are a job's to read (docs/spec/history.md).
  if type(cfg.world.history) == "table" then
    if talker.tools.history then fail("the talker declares a tool %q, which is the conversation's own", "history") end
    local kits = require "kits"
    spec.add_tool(talker, "history", (kits.history_tools()).history)
    talker.system = (talker.system or "") .. "\n- To say what was done before, today or another day, call history: "
      .. "each line is one run kept, with what it was asked. For more than the listing says, hand off a job."
  end
  local lines = { "The workers you can hand work to:" }
  for i = 1, #roster do
    local about = first_line(workers[roster[i]].system)
    lines[#lines + 1] = "- " .. roster[i] .. (about and (": " .. about) or "")
  end
  talker.system = (talker.system or "") .. "\n\n" .. table.concat(lines, "\n")
  c.talker = talker
  return c
end

return speech
