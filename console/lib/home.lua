-- home — the console's home screen: a conversation with an agent, spoken or typed.
--
--     local home = require "console.lib.home"
--     local h = home.new { conversation = c, clock = now }    -- c from agent.speech
--     h:attach_voice(v, tts)            -- console/ml/voice.lua over the same conversation
--     h:key("t"); h:text("hello"); h:key("return")
--     h:update()                        -- every frame
--     local view = h:view(w, hgt, measure)
--     h:hit(x, y)                       -- the action under a point, or nil
--
-- The conversation is spec/speech.md's: a fast talker answers, and agents work behind it
-- as jobs. The voice is optional. Without it, a reply's sentences go to the transcript as
-- soon as they are written; with it, they are spoken, and the microphone is open while
-- Talk is on. Nothing here names `love`: the host draws the view, and passes the keys,
-- the text, the pointer and the microphone's level in.
--
-- The view is a list of shapes and text in window pixels. The window is a stage above a
-- bar along its foot (console/lib/bar.lua). The bar is all the agent shows of itself: a
-- grid of dots, dark when nothing is happening, grey while the person is heard and in
-- colour while the agent speaks. The caption, or the line being typed, is written in its
-- middle, and the actions are hints at its ends while the pointer is over it; the dots
-- under text rest. The stage holds the agent's own file (console/lib/agent_file.lua), or
-- the transcript while it is open (Tab), and nothing else.

local bar = require "console.lib.bar"
local agent_file = require "console.lib.agent_file"
local observe = require "observe"
local authoring = require "authoring"

local home = {}

-- The actions, as hints on the bar: `side` is the end of the bar each sits at. `key` is the
-- key that does it, as the host names keys.
home.TOOLBAR = {
  { action = "talk",       label = "Talk",       key = "space",  shows = "Space", side = "left" },
  { action = "type",       label = "Type",       key = "t",      shows = "T",     side = "left" },
  { action = "transcript", label = "Transcript", key = "tab",    shows = "Tab",   side = "left" },
  { action = "captions",   label = "Captions",   key = "c",      shows = "C",     side = "right" },
  { action = "voice",      label = "Voice",      key = "m",      shows = "M",     side = "right" },
  { action = "stop",       label = "Stop",       key = "escape", shows = "Esc",   side = "right" },
}

home.PAPER = { 0.11, 0.11, 0.12 }    -- the stage: a dark reader, a shade above the bar
home.INK = { 0.90, 0.89, 0.86 }      -- text on the stage
home.LIGHT = { 0.96, 0.95, 0.93 }    -- text on the bar

home.READ_RATE = 15        -- characters a second a caption is read at, a line at a time
home.CAPTION_HOLD = 6      -- seconds a caption stays, once it is read, before it fades
home.CAPTION_FADE = 1.5    -- seconds it takes to fade
home.KEEP = 400            -- transcript lines kept
home.FOLD = 6              -- seconds a finished run stays open on the file before it folds

local H = {}
H.__index = H

local function by_key()
  local m = {}
  for _, t in ipairs(home.TOOLBAR) do m[t.key] = t.action end
  return m
end
local KEYS = by_key()

--- A home screen over a conversation. opts: conversation (required), clock (a function
--- answering seconds), voice_why (why there is no voice yet, shown until there is one).
function home.new(opts)
  if type(opts) ~= "table" or type(opts.conversation) ~= "table" then
    error("home.new needs a conversation (agent.speech)", 2)
  end
  local h = setmetatable({
    c = opts.conversation, clock = opts.clock or function () return 0 end,
    lines = {}, draft = "", typing = false, mic_open = false, voice_on = true, captions_on = true,
    transcript_open = false, scroll = 0, level = 0, partial = nil, caption = nil,
    voice_why = opts.voice_why or "there is no voice", hits = {}, typed = 0,
    bar = bar.new(), file = agent_file.new(), observed_cache = {},
  }, H)
  local was = h.c.on
  h.c.on = function (event, data)
    if was then was(event, data) end
    h:conversation_event(event, data)
  end
  return h
end

-- ------------------------------------------------------------------ the transcript

function H:add(who, text)
  local l = { who = who, text = tostring(text or ""), at = self.clock() }
  self.lines[#self.lines + 1] = l
  if #self.lines > home.KEEP then table.remove(self.lines, 1) end
  return l
end

function H:set_caption(who, text)
  self.caption = { who = who, text = text, at = self.clock() }
end

function H:conversation_event(event, d)
  d = d or {}
  if event == "reply" then
    self.last_reply = self:add("agent", d.text)
    if not self:speaking_aloud() then self:set_caption("agent", d.text) end
  elseif event == "cut" then
    if self.last_reply then self.last_reply.cut = d.said or "" end
  elseif event == "job" then
    if d.state == "running" and d.steps == 0 then
      self:add("job", d.id .. " started: " .. tostring(d.worker))
    elseif d.state ~= "running" and d.state ~= "asking" and d.state ~= "starting" then
      self:add("job", d.id .. " " .. tostring(d.state) .. " after " .. tostring(d.steps)
        .. (d.steps == 1 and " step" or " steps"))
    end
  elseif event == "question" then
    self:add("ask", d.id .. " asks to run " .. tostring(d.tool) .. ". Say or type yes or no.")
  elseif event == "failed" then
    local l = self:add("error", "The talker failed: " .. tostring(d.reason))
    self:set_caption("error", l.text)
  end
end

function H:voice_event(event, d)
  if event == "speech" then
    self.partial = ""
  elseif event == "partial" then
    self.partial = d
    self:set_caption("you", d)
  elseif event == "heard" then
    self.partial = nil
    self:add("you", d)
    self:set_caption("you", d)
  elseif event == "reply" then          -- a sentence the voice is about to say
    self:set_caption("agent", d)
  elseif event == "interrupted" then
    self:add("note", "Stopped.")
  end
end

-- ------------------------------------------------------------------ the voice

--- Gives the screen a voice (console/ml/voice.lua with this conversation as its mind).
--- `tts` is the voice's speech part, kept so Voice can be turned off and on again.
function H:attach_voice(v, tts)
  self.v, self.tts = v, tts or v.tts
  self.voice_why = nil
  local was = v.on
  v.on = function (event, data)
    if was then was(event, data) end
    self:voice_event(event, data)
  end
  if not self.voice_on then v.tts = nil end
end

--- The agent's own feature file, shown on the stage. Answers true, or nil and why.
function H:set_file(text)
  local ok, why = self.file:set(text)
  if ok then self.file_text = text end
  return ok, why
end

--- Runs the file's scenarios on the doubles and marks each one on the stage, passed or
--- failed. `fs` is the workspace's port and `dir` the folder the file is in, for the
--- files it reads. Answers the results, or nil and why the file would not load.
function H:verify(fs, dir)
  if not self.file_text then return nil, "no file" end
  local results, why = authoring.verify(self.file_text, fs, dir or "")
  self.file:results(results)
  if not results then return nil, why end
  return results
end

-- The runs a job delegated, from its trace (docs/spec/trace.md): each invoke_agent span
-- under the job's own, with the tools it called and how it stopped, in the vocabulary's
-- lines. The trace carries names, counts and terms and never a word of what was said, so
-- these lines say what was done and not with what.
local function delegated(j, folded)
  local spans = j.spans or {}
  if #spans < 2 or folded then return {} end
  local by_id = {}
  for _, sp in ipairs(spans) do by_id[sp.id] = sp end
  local root = spans[1].id
  local function nearest(sp, what)
    local p = by_id[sp.parent]
    while p do
      if p.name:find("^" .. what .. " ") then return p end
      p = by_id[p.parent]
    end
  end
  local out = {}
  for _, sp in ipairs(spans) do
    if sp.id ~= root and sp.name:find("^invoke_agent ") then
      local through = nearest(sp, "execute_tool")
      local name = sp.name:sub(#"invoke_agent " + 1)
      local lines = { "  Scenario: " .. name .. (through and (", handed " .. through.name:sub(#"execute_tool " + 1)) or "") }
      local first = true
      local function say(l) lines[#lines + 1] = "    " .. (first and "Then " or "And ") .. l; first = false end
      local stop = sp.attrs["malleable.stop"]
      if stop ~= nil then
        say("it stops with " .. tostring(stop))
        local n = tonumber(sp.attrs["malleable.steps"]) or 0
        say("it takes " .. n .. (n == 1 and " step" or " steps"))
      end
      for _, c in ipairs(spans) do
        if c.name:find("^execute_tool ") and nearest(c, "invoke_agent") == sp then
          local tool = c.name:sub(#"execute_tool " + 1)
          if c.attrs["malleable.gate.answer"] == "refused" then say("the call to " .. tool .. " is refused")
          elseif c.ok == false then say("the call to " .. tool .. " fails")
          else say("it calls " .. tool) end
        end
      end
      out[#out + 1] = { id = j.id .. "/" .. sp.id, parent = j.id, text = table.concat(lines, "\n") .. "\n",
                        state = stop == nil and "running" or (stop == "answered" and "passed" or "failed") }
    end
  end
  return out
end

-- The jobs as observed scenarios for the file: the calls so far while one runs, the run's
-- own result once it ended, and one folded line home.FOLD seconds after that; the runs
-- it delegated nest under it.
function H:observed(now)
  local blocks = {}
  for _, j in ipairs(self.c:jobs()) do
    local state = "running"
    if j.state == "asking" then state = "waiting"
    elseif j.state == "done" then state = "passed"
    elseif j.state ~= "running" and j.state ~= "starting" then state = "failed" end
    local folded = j.ended ~= nil and now - j.ended >= home.FOLD
    local result = j.result or { calls = j.calls or {}, steps = j.steps }
    local key = table.concat({ j.state, #(result.calls or {}), tostring(result.stop), tostring(folded) }, ":")
    local kept = self.observed_cache[j.id]
    if not kept or kept.key ~= key then
      local title = j.id .. " " .. tostring(j.worker) .. ": " .. tostring(j.task or "")
      if #title > 72 then title = title:sub(1, 69) .. "..." end
      local text = observe.live({ result = result, prompt = j.task, log = j.log }, title)
      kept = { key = key, text = text }
      self.observed_cache[j.id] = kept
    end
    blocks[#blocks + 1] = { id = j.id, text = kept.text, state = folded and "folded" or state,
                            note = folded and (tostring(j.state) .. " after " .. tostring(j.steps) .. (j.steps == 1 and " step" or " steps")) or nil }
    for _, child in ipairs(delegated(j, folded)) do blocks[#blocks + 1] = child end
  end
  self.file:observed(blocks)
end

--- The voice could not be had, and why.
function H:no_voice(why)
  self.v, self.tts, self.mic_open = nil, nil, false
  self.voice_why = why
end

function H:speaking_aloud()
  return self.v ~= nil and self.v.tts ~= nil
end

-- ------------------------------------------------------------------ actions

--- Does an action. Answers true, or false and why not.
function H:act(action)
  if action == "talk" then
    if not self.v then
      local l = self:add("note", "Talk needs the voice, and there is none yet: " .. tostring(self.voice_why) .. ".")
      self:set_caption("note", l.text)
      return false, self.voice_why
    end
    self.mic_open = not self.mic_open
    return true
  elseif action == "type" then
    self.typing = not self.typing
    return true
  elseif action == "transcript" then
    self.transcript_open = not self.transcript_open
    self.scroll = 0
    return true
  elseif action == "captions" then
    self.captions_on = not self.captions_on
    return true
  elseif action == "voice" then
    self.voice_on = not self.voice_on
    if self.v then
      if self.voice_on then
        self.v.tts = self.tts
      else
        if self.v.speaker then self.v.speaker:clear() end
        self.v.tts = nil
      end
    end
    return true
  elseif action == "stop" then
    if self.v and self.v.interrupt then
      self.v:interrupt()
    elseif self.c:busy() then
      self.c:cut()
      self:add("note", "Stopped.")
    end
    return true
  end
  return false, "no action called " .. tostring(action)
end

--- Whether there is a reply to stop.
function H:stoppable()
  if self.c:busy() then return true end
  return self.v ~= nil and (self.v.saying ~= nil or (self.v.speaker ~= nil and self.v.speaker:queued() > 0))
end

--- Sends a typed turn.
function H:send(text)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return false end
  self:add("you", text)
  self:set_caption("you", text)
  self.c:heard(text)
  return true
end

local function drop_last_char(s)
  local n = #s
  while n > 0 do
    local b = s:byte(n)
    if b < 128 or b >= 192 then break end
    n = n - 1
  end
  return s:sub(1, math.max(0, n - 1))
end

--- A key, as the host names it. Answers true if the screen used it.
function H:key(k)
  if self.typing then
    if k == "return" or k == "kpenter" then
      local text = self.draft
      self.draft = ""
      self:send(text)
      return true
    elseif k == "escape" then
      self.typing = false
      return true
    elseif k == "backspace" then
      self.draft = drop_last_char(self.draft)
      return true
    end
    return true                           -- every other key is typing, and comes as text
  end
  if self.transcript_open then
    if k == "up" or k == "pageup" then self.scroll = self.scroll + (k == "up" and 1 or 8); return true end
    if k == "down" or k == "pagedown" then self.scroll = math.max(0, self.scroll - (k == "down" and 1 or 8)); return true end
  end
  if k == "escape" and not self:stoppable() and self.transcript_open then
    self.transcript_open = false
    return true
  end
  local action = KEYS[k]
  if not action then return false end
  if action == "type" then self.swallow = "t" end   -- the T that opened it is not typing
  self:act(action)
  return true
end

--- Text the person typed.
function H:text(t)
  if not self.typing then return false end
  if self.swallow and t:lower() == self.swallow then self.swallow = nil; return true end
  self.swallow = nil
  self.draft = self.draft .. t
  self.typed = self.typed + 1          -- each key typed lights the bar at the caret
  return true
end

function H:wheel(dy)
  if not self.transcript_open then
    self.file:wheel(dy)
    return
  end
  self.scroll = math.max(0, self.scroll + (dy > 0 and 2 or -2))
end

--- The microphone's loudness now, 0 to 1 (the host reads it from the buffer it gave).
function H:hear_level(x)
  self.level = math.max(0, math.min(1, x or 0))
end

-- ------------------------------------------------------------------ the frame

--- One slice: the voice (which drives the conversation) or the conversation alone.
function H:update()
  if self.v then
    self.v:update()
  else
    self.c:update()
    local s = self.c:take()
    while s do self.c:said(); s = self.c:take() end
  end
end

--- What is happening: mode, the jobs working, and the questions waiting.
function H:status()
  local working, asking = 0, {}
  for _, j in ipairs(self.c:jobs()) do
    if j.state == "running" or j.state == "starting" then working = working + 1
    elseif j.state == "asking" then asking[#asking + 1] = j.id end
  end
  local mode = "ready"
  local v = self.v
  if v and v.state == "speaking" then mode = "hearing you"
  elseif v and (v.saying or (v.speaker and v.speaker:queued() > 0)) then mode = "speaking"
  elseif self.c:busy() then mode = "thinking"
  elseif self.mic_open then mode = "listening" end
  return { mode = mode, working = working, asking = asking }
end

-- ------------------------------------------------------------------ the view

-- Lines of at most `w` pixels, words kept whole unless one is wider than a line.
function home.wrap(text, w, measure, size)
  local out, line = {}, ""
  for word in tostring(text or ""):gmatch("%S+") do
    local try = line == "" and word or (line .. " " .. word)
    if measure(try, size) <= w then
      line = try
    else
      if line ~= "" then out[#out + 1] = line end
      line = word
      while measure(line, size) > w and #line > 1 do
        local n = #line - 1
        while n > 1 and measure(line:sub(1, n), size) > w do n = n - 1 end
        out[#out + 1] = line:sub(1, n)
        line = line:sub(n + 1)
      end
    end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

local WHO = {
  you = "You", agent = "Agent", job = "Job", ask = "Asks", error = "Error", note = "",
}

--- Where the pointer is over the window, or nil once it has left: the hints show while it
--- is over the bar.
function H:pointer(x, y)
  if x == nil or y == nil then self.pointer_at = nil else self.pointer_at = { x = x, y = y } end
end

-- What the bar is showing: the agent speaking, the person heard (or typing), or neither.
function H:bar_state(st, now)
  if st.mode == "speaking" then return "speaking" end
  if st.mode == "hearing you" or st.mode == "listening" then return "hearing" end
  -- with no voice, a reply is read, not heard: the agent speaks for as long as reading it takes
  local cap = self.caption
  if not self:speaking_aloud() and cap and cap.who == "agent" and cap.text
    and now - cap.at < 0.6 + #cap.text / home.READ_RATE then return "speaking" end
  if self.typing then return "hearing" end
  return "quiet"
end

--- The loudness of what the voice is saying now, 0 to 1 (the host measures it as it plays).
function H:say_level(x)
  self.said_level = math.max(0, math.min(1, x or 0))
end

-- The caption's line to show now, at most `room` pixels wide, and when its reading ends.
-- While the person is still speaking it is the last line, what they are saying now;
-- otherwise the lines come in turn, at the pace they are read.
function H:caption_line(cap, now, room, measure, size)
  local lines = home.wrap(cap.text, room, measure, size)
  if #lines == 0 then return nil, cap.at end
  if cap.who == "you" and self.partial ~= nil then return lines[#lines], cap.at end
  local ends = cap.at + #cap.text / home.READ_RATE
  local t, chars = now - cap.at, 0
  for i, l in ipairs(lines) do
    chars = chars + #l + 1
    if t < chars / home.READ_RATE or i == #lines then return l, ends end
  end
end

-- What there is to show on the stage, as rows: the transcript while it is open.
function H:content(measure, small, size)
  if self.transcript_open then
    local rows, label_w = {}, 0
    for _, label in pairs(WHO) do label_w = math.max(label_w, measure(label, small)) end
    for _, l in ipairs(self.lines) do
      local label = WHO[l.who] or ""
      rows[#rows + 1] = { label = label ~= "" and label or nil, quiet = l.who == "note",
                          text = l.cut and (l.cut .. " (cut here)") or l.text }
    end
    if self.partial and self.partial ~= "" then rows[#rows + 1] = { label = "You", text = self.partial .. " ...", quiet = true } end
    if #rows == 0 then rows[1] = { text = "Nothing said yet.", quiet = true } end
    return { title = "Transcript", rows = rows, from = "bottom", scroll = self.scroll, spaced = true,
             label_w = label_w + size }
  end
end

-- The content's rows, drawn in the rectangle `r`.
local function draw_content(push, ct, r, measure, size, ink)
  local lh = math.floor(size * 1.45)
  local top = r.y
  if ct.title then
    push { kind = "text", text = ct.title, x = r.x, y = top, size = size, rgb = ink, alpha = 1 }
    top = top + lh * 2
  end
  local rows = {}
  for _, row in ipairs(ct.rows or {}) do
    local label_w = ct.label_w or (row.label and (measure(row.label, size) + size) or 0)
    local lines = {}
    for raw in (tostring(row.text or "") .. "\n"):gmatch("(.-)\n") do
      if raw == "" then lines[#lines + 1] = "" else
        for _, l in ipairs(home.wrap(raw, r.w - label_w, measure, size)) do lines[#lines + 1] = l end
      end
    end
    for i, l in ipairs(lines) do
      rows[#rows + 1] = { label = i == 1 and row.label or nil, text = l, indent = label_w, quiet = row.quiet }
    end
    if ct.spaced then rows[#rows + 1] = { text = "", indent = 0 } end
  end
  local fit = math.max(1, math.floor((r.y + r.h - top) / lh))
  local first, last = 1, math.min(#rows, fit)
  if ct.from == "bottom" then
    last = math.max(math.min(#rows, fit), #rows - (ct.scroll or 0))
    first = math.max(1, last - fit + 1)
  end
  for i = first, last do
    local row = rows[i]
    local y = top + (i - first) * lh
    if row.label then push { kind = "text", text = row.label, x = r.x, y = y, size = size, rgb = ink, alpha = 0.5 } end
    push { kind = "text", text = row.text, x = r.x + row.indent, y = y, size = size, rgb = ink, alpha = row.quiet and 0.5 or 1 }
  end
end

--- The screen at `w` by `hgt` window pixels. `measure(text, size)` answers a text's width.
--- Answers { stage = the rectangle left for what the agent makes, bar = the strip along the
--- foot, items = { ... }, size = the text size }. Every place is worked out from `w` and
--- `hgt` alone, so a window of any size is laid out at once.
function H:view(w, hgt, measure)
  local items, hits = {}, {}
  local function push(it) items[#items + 1] = it end
  local function say(s, x, y, size, alpha)
    push { kind = "text", text = s, x = x, y = y, size = size, rgb = home.LIGHT, alpha = alpha or 1 }
  end

  local size = math.max(12, math.min(18, math.floor(math.min(hgt / 40, w / 32))))
  local small = math.max(11, size - 2)
  local pad = math.floor(size * 0.9)
  local bar_h = math.floor(small * 2.6)
  local bar_y = hgt - bar_h
  local now = self.clock()
  local st = self:status()
  local state = self:bar_state(st, now)

  -- the hints fade in while the pointer is over the bar (or just above it), and out after
  local dt = self.viewed_at and math.max(0, math.min(0.2, now - self.viewed_at)) or 1
  self.viewed_at = now
  local p = self.pointer_at
  local want = (not self.typing and p and p.x >= 0 and p.x < w and p.y >= bar_y - bar_h and p.y < hgt) and 1 or 0
  local ha = self.hint_alpha or want
  ha = want > ha and math.min(want, ha + dt * 6) or math.max(want, ha - dt * 3)
  self.hint_alpha = ha

  -- the stage, and what there is to show on it
  push { kind = "rect", x = 0, y = 0, w = w, h = bar_y, rgb = home.PAPER, alpha = 1 }
  local ct = self:content(measure, small, size)
  if ct then
    local m = math.max(pad * 2, math.floor(w * 0.06))
    draw_content(push, ct, { x = m, y = pad * 2, w = w - m * 2, h = bar_y - pad * 4 }, measure, small, home.INK)
  else
    self:observed(now)
    for _, it in ipairs(self.file:draw({ x = 0, y = 0, w = w, h = bar_y }, measure, small, now)) do push(it) end
  end

  -- the middle of the bar: the line being typed, else the caption
  local text_y = bar_y + math.floor((bar_h - size * 1.15) / 2)
  local room = math.min(math.floor(size * 40), math.floor(w * 0.6))    -- the ends are left to the dots
  local middle
  if self.typing and self.draft ~= "" then
    local shown = self.draft
    while #shown > 0 and measure(shown, size) > room do shown = shown:sub(2) end
    middle = { text = shown, alpha = 1, typed = true }
  else
    local cap = self.caption
    if self.captions_on and not self.transcript_open and cap and cap.text and cap.text ~= "" then
      local line, ends = self:caption_line(cap, now, room, measure, size)
      local talking = self.partial ~= nil or (self.v and self.v.saying)
      local a = 1
      if not talking and now - ends > home.CAPTION_HOLD then a = 1 - (now - ends - home.CAPTION_HOLD) / home.CAPTION_FADE end
      if line and a > 0 then middle = { text = line, alpha = a * ((cap.who == "you" or cap.who == "note") and 0.7 or 1) } end
    end
    if self.typing and not middle then
      middle = { text = "Type to the agent. Enter sends, Esc closes.", alpha = 0.45, empty = true, typed = true }
    end
  end
  local still = {}
  if middle then
    middle.alpha = middle.alpha * (1 - ha)
    middle.w = measure(middle.text, size)
    middle.x = math.floor((w - middle.w) / 2)
    if middle.alpha > 0.02 then still[#still + 1] = { middle.x - pad, middle.x + middle.w + pad } end
  end

  -- the hints: each action and its key, small, at the two ends of the bar
  local placed = {}
  if ha > 0.02 then
    local sides = { left = {}, right = {} }
    for _, t in ipairs(home.TOOLBAR) do
      local label, off = t.label:lower(), false
      if t.action == "talk" then off = not self.v; if self.mic_open then label = "talking" end
      elseif t.action == "transcript" then if self.transcript_open then label = "transcript open" end
      elseif t.action == "captions" then if not self.captions_on then label = "captions off" end
      elseif t.action == "voice" then if not self.voice_on then label = "voice off" end
      elseif t.action == "stop" then off = not self:stoppable() end
      local s = sides[t.side]
      s[#s + 1] = { t = t, label = label, off = off }
    end
    -- labels go when the window is too narrow for them, and the keys stay
    local gap, inner = math.floor(small * 1.4), math.floor(small * 0.45)
    local function widths(bare)
      local total = 0
      for _, s in pairs(sides) do
        for i, e in ipairs(s) do
          e.kw = measure(e.t.shows, small)
          e.w = e.kw + (bare and 0 or (inner + measure(e.label, small)))
          total = total + e.w + (i > 1 and gap or 0)
        end
      end
      return total
    end
    local bare = widths(false) + pad * 2 + gap * 2 > w
    if bare then widths(true) end
    local x = pad
    for _, e in ipairs(sides.left) do e.x = x; placed[#placed + 1] = e; x = x + e.w + gap end
    still[#still + 1] = { 0, x }
    x = w - pad
    for i = #sides.right, 1, -1 do
      local e = sides.right[i]
      x = x - e.w
      e.x = x
      placed[#placed + 1] = e
      x = x - gap
    end
    still[#still + 1] = { x, w }
    for _, e in ipairs(placed) do e.bare, e.inner = bare, inner end
  end

  -- the bar: each key typed lights the dots just past the end of the line
  local tail = middle and (middle.x + (middle.empty and 0 or middle.w) + pad + bar.PITCH) or w / 2
  while self.typed > 0 do
    self.bar:pour(tail / w, 0.9)
    self.typed = self.typed - 1
  end
  local level = self.level
  if state == "speaking" then
    if self:speaking_aloud() and self.said_level then level = self.said_level
    else level = math.max(0, math.min(1, 0.55 + 0.45 * math.sin(now * 9) * math.sin(now * 2.3 + 1))) end
  end
  for _, it in ipairs(self.bar:draw { x = 0, y = bar_y, w = w, h = bar_h, now = now, state = state,
                                      level = level, still = still }) do
    push(it)
  end

  if middle and middle.alpha > 0.02 then
    say(middle.text, middle.x, text_y, size, middle.alpha)
  end
  -- the caret, on the person's own line only: never after the agent's words
  if self.typing and middle and middle.typed and math.floor(now * 2) % 2 == 0 then
    local cx = middle.empty and middle.x - 4 or middle.x + middle.w + 1
    push { kind = "rect", x = cx, y = text_y, w = 2, h = math.floor(size * 1.2), rgb = home.LIGHT, alpha = 1 }
  end
  local hint_y = bar_y + math.floor((bar_h - small * 1.15) / 2)
  for _, e in ipairs(placed) do
    local a = ha * (e.off and 0.4 or 1)
    say(e.t.shows, e.x, hint_y, small, a * 0.55)
    if not e.bare then say(e.label, e.x + e.kw + e.inner, hint_y, small, a * 0.95) end
    hits[#hits + 1] = { x = e.x - 4, y = bar_y, w = e.w + 8, h = bar_h, action = e.t.action }
  end

  self.hits = hits
  return { stage = { x = 0, y = 0, w = w, h = bar_y }, bar = { x = 0, y = bar_y, w = w, h = bar_h },
           items = items, size = size }
end

--- The action under a point in the last view, or nil.
function H:hit(x, y)
  for _, r in ipairs(self.hits) do
    if r.action ~= "transcript_area" and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h then
      return r.action
    end
  end
end

--- A mouse press at (x, y): a hint does its action. Answers the action or nil.
function H:press(x, y)
  local a = self:hit(x, y)
  if a then
    if a == "type" then self.swallow = nil end
    self:act(a)
  end
  return a
end

return home
