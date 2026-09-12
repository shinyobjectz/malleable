-- The LÖVE host: one window with an agent in it. The only file in the console that names
-- `love`, and one of the few in the tree that touch the real world (with bin/malleable.lua,
-- bin/world.lua and bin/curl.lua).
--
--     love console                              talk or type to the default agent
--     love console --agent a.feature --root D   that agent, with its tools over that folder
--     love console --no-voice                   without the voice's models
--     love console --script steps.txt           a scripted person, for checks without one
--
-- The screen is console/lib/home.lua: a talker in front of an agent's jobs (spec/speech.md),
-- spoken or typed, the stage above and the bar along the foot (spec/home.md). It is an
-- ordinary window, drawn at the window's own resolution, and it knows nothing of `love`:
-- this file draws the items it answers and passes it the keys, the text, the pointer and
-- the microphone. The agent is --agent (a .feature, or a .lua declaration;
-- console/agents/notebook.feature by default), and its tools see --root
-- (~/.malleable/home by default). The world is bin/world.lua's real ports, whose network
-- calls yield inside a run, so a frame never waits on them. The voice's models load on
-- the third frame, so the window is up first.
--
-- --script FILE plays a person, one step a line:
--
--     key t | text what do my notes say? | key return | wait reply 40 | shot a.png
--     listen turn.wav | wait heard 30 | wait quiet 60 | quit
--
-- `wait` takes reply, heard, quiet or a number of seconds, and a limit; `click ACTION`
-- presses a hint on the bar; `point X Y` clicks the window; `pointer on|off|X Y` brings the
-- pointer over the bar, takes it away or puts it at a place; `size W H` makes the window
-- that size; `shot` saves a PNG under console/captures/ unless the path is absolute.

-- From the tree, `love console` runs this folder and the harness is beside it; shipped
-- (scripts/ship.sh), the .love holds the tree with this file at its root, and the agents
-- and the harness are read from the archive. The voice's engine loads a native library
-- from console/ml on disk, so a shipped console speaks only with the tree beside it.
local source = love.filesystem.getSource()
local archive = love.filesystem.getInfo("src/speech.lua") ~= nil
local root = archive and source or (source:match("^(.*)[/\\][^/\\]+[/\\]?$") or "..")
if archive then
  love.filesystem.setRequirePath("?.lua;?/init.lua;src/?.lua;bin/?.lua")
else
  package.path = root .. "/?.lua;" .. root .. "/src/?.lua;" .. root .. "/bin/?.lua;" .. package.path
end

local home_lib = require "console.lib.home"

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function mkdir(path)
  os.execute('mkdir -p "' .. path .. '"')
end

local function parse(args)
  local o = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--agent" then o.agent = args[i + 1]; i = i + 2
    elseif a == "--root" then o.root = args[i + 1]; i = i + 2
    elseif a == "--no-voice" then o.no_voice = true; i = i + 1
    elseif a == "--script" then o.script = args[i + 1]; i = i + 2
    else i = i + 1 end
  end
  return o
end

-- On macOS a new window is not always the key window; without this the keyboard is silent
-- until something else focuses it.
local raise_window
do
  local ok, ffi = pcall(require, "ffi")
  if ok then
    pcall(function ()
      ffi.cdef [[
        void *SDL_GL_GetCurrentWindow(void);
        void SDL_RaiseWindow(void *window);
        int SDL_SetWindowInputFocus(void *window);
      ]]
      local sdl = ffi.C
      if ffi.os == "Windows" then
        local loaded, lib = pcall(ffi.load, "SDL2")
        if loaded then sdl = lib end
      end
      raise_window = function ()
        local win = sdl.SDL_GL_GetCurrentWindow()
        if win ~= nil and win ~= ffi.NULL then
          sdl.SDL_RaiseWindow(win)
          sdl.SDL_SetWindowInputFocus(win)
        end
      end
    end)
  end
end

local function claim_focus()
  if raise_window then pcall(raise_window) end
end

-- ------------------------------------------------------------------ the agent and its world

local H = nil     -- the screen's state, once it is open

local fonts = {}
local function font(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
  return fonts[size]
end

local function measure(text, size)
  return font(size):getWidth(text)
end

-- The agents the talker hands work to. The one on the stage is --agent, or the notebook in
-- the workspace's own agents/ folder; the author beside it edits the files there, its own
-- included (docs/spec/agent-file.md). Both are put there from console/agents/ the first
-- time. Answers the surface, the path of the file shown, and the workers by name.
local SEEDS = { "notebook", "author", "reader" }     -- put in the workspace the first time
local KIT_SEEDS = { ["modes.lua"] = "library/modes.lua" }   -- the kits the seeded agents use (docs/spec/modes.md)
local WORKERS = { "notebook", "author" }             -- the talker's own; the reader is the notebook's delegate

local function load_agent(o, dir)
  local agent = require "agent"
  local declare, spec = require "declare", require "spec"
  local folder = dir .. "/agents"
  for _, name in ipairs(SEEDS) do
    local path = folder .. "/" .. name .. ".feature"
    if not read_file(path) then
      local seed = archive and love.filesystem.read("console/agents/" .. name .. ".feature")
                   or read_file(root .. "/console/agents/" .. name .. ".feature")
      if seed then mkdir(folder); write_file(path, seed) end
    end
  end
  for name, source in pairs(KIT_SEEDS) do
    local path = folder .. "/" .. name
    if not read_file(path) then
      local seed = archive and love.filesystem.read(source) or read_file(root .. "/" .. source)
      if seed then mkdir(folder); write_file(path, seed) end
    end
  end
  local path = o.agent or (folder .. "/notebook.feature")
  local text = read_file(path)
  if not text then return nil, "no agent at " .. path end
  local from = path:match("^(.*)[/\\][^/\\]*$") or "."
  local function read(p)
    local t = read_file(from .. "/" .. p)
    if not t then return nil, "no such file" end
    return t
  end
  local ok, why
  if path:match("%.feature$") then ok, why = pcall(agent.declare, text, { read = read })
  else ok, why = pcall(dofile, path) end
  if not ok then return nil, tostring(why) end
  local main = agent.spec()
  local workers = { [main.name] = main }
  for _, name in ipairs(WORKERS) do
    local other = read_file(folder .. "/" .. name .. ".feature")
    if other and folder .. "/" .. name .. ".feature" ~= path then
      local s = spec.new()
      local info, bad = declare.apply(other, s, { read = read })
      if info and s.name and not workers[s.name] then workers[s.name] = s
      else print("home: " .. name .. ".feature is left out: " .. tostring(bad or "it declares no name")) end
    end
  end
  return agent, path, workers
end

-- The world the talker and the jobs reach: bin/world.lua's real ports, with the network
-- yielding so a frame never waits on it. With no key, a model that says so.
local function load_world(dir)
  local ok, world = pcall(require, "world")
  local w, why
  if ok then w, why = world.ports { root = dir, yielding = true } else why = tostring(world) end
  if w then return w end
  return { model = { call = function () return nil, { message = why } end } }, why
end

-- ------------------------------------------------------------------ the voice

-- A WAV as the microphone, at the pace it was spoken, then quiet.
local function wav_mic(ml, path)
  local x, rate = ml.wav_read(path)
  if rate ~= 16000 then x = ml.resample(x, rate, 16000) end
  local start, given = ml.now(), 0
  return { read = function ()
    local due = math.floor((ml.now() - start) * 16000)
    if due <= given then return ml.buffer(0) end
    local b = given < #x and x:slice(given + 1, math.min(due, #x)) or ml.buffer(0)
    if due > #x then b = ml.join(b, ml.buffer(due - math.max(given, #x))) end
    given = due
    return b
  end, start = function () end }
end

-- The speaker, measured: the loudness of every fiftieth of a second written to it is kept
-- until it is played, so `level()` answers the loudness of what is being heard now.
local function measured(speaker, rate)
  local block = math.floor(rate / 50)
  local written, blocks, first, last = 0, {}, 1, 0
  local m = {}
  function m.start() return speaker:start() end
  function m.queued() return speaker:queued() end
  function m.clear() return speaker:clear() end
  function m.write(_, samples)
    local took = speaker:write(samples)
    local i = 1
    while i <= took do
      local j = math.min(took, i + block - 1)
      local lo, hi = samples:slice(i, j):stats()
      last = last + 1
      blocks[last] = { at = written + i - 1, peak = math.max(math.abs(lo), math.abs(hi)) }
      i = j + 1
    end
    written = written + took
    return took
  end
  function m.level()
    local now = written - speaker:queued()
    while first < last and blocks[first + 1].at <= now do blocks[first] = nil; first = first + 1 end
    local b = blocks[first]
    if not b or b.at > now or now - b.at >= block then return 0 end
    return b.peak
  end
  return setmetatable(m, { __index = function (_, k)
    local v = speaker[k]
    if type(v) == "function" then return function (_, ...) return v(speaker, ...) end end
    return v
  end })
end

-- The voice: the microphone, Silero VAD, Smart Turn, Moonshine, Pocket TTS and the speaker,
-- over the conversation (console/ml/voice.lua). The microphone reaches the voice only while
-- Talk is on; otherwise it hears silence, so a turn in progress ends as a pause would end it.
local function load_voice()
  local ok, ml = pcall(require, "console.ml.engine")
  if not ok then return nil, "the ML engine is not built (console/ml/build.sh luajit)" end
  local models = root .. "/console/ml/models"
  for _, n in ipairs { "silero-vad.gguf", "smart-turn-v3.2.gguf", "moonshine-streaming-small-f32.gguf",
                       "pocket-tts.gguf", "pocket-tts-alba.gguf" } do
    local f = io.open(models .. "/" .. n, "rb")
    if not f then return nil, "no " .. n .. " in console/ml/models" end
    f:close()
  end
  local voice = require "console.ml.voice"
  local gpu = ml.engine { device = "auto", threads = 4 }
  local one = ml.engine { device = "cpu", threads = 1 }
  local vad = require("console.ml.silero_vad").load(one, models .. "/silero-vad.gguf")
  local turn = require("console.ml.smart_turn").load(gpu, models .. "/smart-turn-v3.2.gguf")
  local asr = require("console.ml.moonshine").load(gpu, models .. "/moonshine-streaming-small-f32.gguf")
  local pocket = require("console.ml.pocket_tts").load(gpu, models .. "/pocket-tts.gguf",
    { voice = models .. "/pocket-tts-alba.gguf" })
  local tts = { rate = pocket.rate or (pocket.hp and pocket.hp.rate) or 24000,
                speak = function (_, text, o) return pocket:speak(text, o) end }
  local speaker = measured(ml.speaker { rate = tts.rate }, tts.rate)
  speaker:start()
  H.ml = ml
  H.source = ml.microphone { rate = 16000 }
  H.source:start()
  local zeros_since = nil
  local mic = { read = function ()
    local b = H.source:read()
    if #b == 0 then return b end
    if not H.h.mic_open then H.h:hear_level(0); zeros_since = nil; return ml.buffer(#b) end
    local lo, hi = b:stats()
    H.h:hear_level(math.max(math.abs(lo), math.abs(hi)) * 2)
    if lo == 0 and hi == 0 then
      zeros_since = zeros_since or ml.now()
      if ml.now() - zeros_since > 2 and not H.said_silent then
        H.said_silent = true
        H.h:add("error", "The microphone hears only silence. Give LÖVE microphone access in System "
          .. "Settings, Privacy & Security, Microphone, then open the console again.")
      end
    else
      zeros_since = nil
    end
    return b
  end }
  local v = voice.new({ mic = mic, vad = vad, turn = turn, asr = asr, tts = tts, speaker = speaker,
                        mind = H.conversation })
  return v, tts
end

-- ------------------------------------------------------------------ --script

-- One step of the script, or nil when it is still waiting.
local function script_step()
  local s = H.script
  local line = s.lines[s.at]
  if not line then return end
  local now = love.timer.getTime()
  s.since = s.since or now
  local verb, rest = line:match("^(%S+)%s*(.*)$")
  local function done(note)
    print(string.format("script %6.2f s  %s%s", now - s.t0, line, note and ("  (" .. note .. ")") or ""))
    s.at, s.since, s.mark = s.at + 1, nil, nil
  end
  if verb == "key" then
    H.h:key(rest)
    done()
  elseif verb == "text" then
    for ch in rest:gmatch("[%z\1-\127\194-\244][\128-\191]*") do H.h:text(ch) end
    done()
  elseif verb == "click" then
    for _, r in ipairs(H.h.hits) do
      if r.action == rest then H.h:press(r.x + 2, r.y + 2); return done() end
    end
    done("no button " .. rest)
  elseif verb == "pointer" then
    local x, y = rest:match("^(%-?%d+)%s+(%-?%d+)")
    local w, hgt = love.graphics.getDimensions()
    if x then H.h:pointer(tonumber(x), tonumber(y))
    elseif rest == "on" then H.h:pointer(w / 2, hgt - 4)
    else H.h:pointer(nil) end
    done()
  elseif verb == "size" then
    local w, hgt = rest:match("^(%d+)%s+(%d+)")
    love.window.updateMode(tonumber(w) or 800, tonumber(hgt) or 600, {})
    done(string.format("%d x %d", love.graphics.getDimensions()))
  elseif verb == "point" then
    local x, y = rest:match("^(%-?%d+)%s+(%-?%d+)")
    H.h:press(tonumber(x) or 0, tonumber(y) or 0)
    done()
  elseif verb == "shot" then
    local path = rest:find("^/") and rest or (love.filesystem.getSaveDirectory() .. "/" .. rest)
    mkdir(path:match("^(.*)/") or ".")
    love.graphics.captureScreenshot(function (data)
      write_file(path, data:encode("png"):getString())
    end)
    done(path)
  elseif verb == "listen" then
    if not H.v then return done("no voice: " .. tostring(H.h.voice_why)) end
    H.source = wav_mic(H.ml, rest)
    H.said_silent = true                  -- a WAV ends in zeros, which is not a closed microphone
    if not H.h.mic_open then H.h:act("talk") end
    done()
  elseif verb == "wait" then
    local what, limit = rest:match("^(%S+)%s*(%S*)")
    limit = tonumber(limit) or 30
    if not s.mark then s.mark = #H.h.lines end
    local met = false
    if tonumber(what) then
      met = now - s.since >= tonumber(what)
    elseif what == "reply" or what == "heard" then
      for i = s.mark + 1, #H.h.lines do
        local who = H.h.lines[i].who
        if (what == "reply" and who == "agent") or (what == "heard" and who == "you") then met = true end
      end
    elseif what == "quiet" then
      local st = H.h:status()
      met = now - s.since > 1 and st.working == 0 and #st.asking == 0 and not H.h:stoppable()
        and #H.conversation.reports == 0 and (st.mode == "ready" or st.mode == "listening")
    end
    if met then return done(string.format("%.2f s", now - s.since)) end
    if now - s.since > limit then return done("gave up after " .. limit .. " s") end
  elseif verb == "quit" then
    done()
    print("script: the transcript")
    for _, l in ipairs(H.h.lines) do
      print(string.format("  %-6s %s%s", l.who, l.text, l.cut and ("  [cut: " .. l.cut .. "]") or ""))
    end
    love.event.quit()
  else
    done("what is " .. tostring(verb) .. "?")
  end
end

-- ------------------------------------------------------------------ LÖVE

local function draw()
  local w, hgt = love.graphics.getDimensions()
  local paper = home_lib.PAPER
  love.graphics.setScissor()
  love.graphics.clear(paper[1], paper[2], paper[3], 1)
  for _, it in ipairs(H.h:view(w, hgt, measure).items) do
    local c = it.rgb or home_lib.INK
    love.graphics.setColor(c[1], c[2], c[3], it.alpha or 1)
    if it.kind == "rect" then
      love.graphics.rectangle("fill", it.x, it.y, it.w, it.h, it.round or 0, it.round or 0)
    elseif it.kind == "circle" then
      love.graphics.circle("fill", it.x, it.y, it.r, it.segments or 32)
    elseif it.kind == "line" then
      love.graphics.setLineWidth(it.width or 1)
      love.graphics.line(it.x1, it.y1, it.x2, it.y2)
      love.graphics.setLineWidth(1)
    elseif it.kind == "clip" then
      love.graphics.setScissor(math.floor(it.x), math.floor(it.y), math.ceil(it.w), math.ceil(it.h))
    elseif it.kind == "unclip" then
      love.graphics.setScissor()
    else
      love.graphics.setFont(font(it.size))
      love.graphics.print(it.text, math.floor(it.x), math.floor(it.y))
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

local function update()
  H.frames = H.frames + 1
  if H.frames == 3 and not H.no_voice then
    local ok, v, tts = pcall(load_voice)
    if ok and v then
      H.v = v
      H.h:attach_voice(v, tts)
      print(string.format("the voice is ready (%.1f s)", love.timer.getTime() - H.t0))
    else
      local why = ok and tts or v
      H.h:no_voice("no voice: " .. tostring(why))
      print("no voice: " .. tostring(why))
    end
  end
  local ok, err = pcall(H.h.update, H.h)
  if not ok then H.h:add("error", tostring(err)); print("home: " .. tostring(err)) end
  -- the agent's file, watched: an edit lands on the stage and its scenarios run again
  if H.file_path and H.frames % 60 == 0 then
    local text = read_file(H.file_path)
    if text and text ~= H.file_text then
      H.file_text = text
      local shown, bad = H.h:set_file(text)
      if shown then
        local t0 = love.timer.getTime()
        local results, why = H.h:verify(H.world.fs, H.file_dir)
        print(string.format("the agent's file changed; %s (%.2f s)", results and (#results .. " scenarios run") or ("it will not load: " .. tostring(why)), love.timer.getTime() - t0))
      else
        print("the agent's file changed and will not show: " .. tostring(bad))
      end
    end
  end
  if H.v and H.v.speaker and H.v.speaker.level then H.h:say_level(H.v.speaker.level() * 2.5) end
  if H.script then script_step() end
end

function love.load(args)
  local o = parse(args or {})
  io.stdout:setvbuf("no")                 -- its lines reach a log as they are printed
  love.keyboard.setKeyRepeat(true)
  if not o.script then claim_focus() end    -- a scripted run must not take the person's keyboard
  local dir = o.root or ((os.getenv("HOME") or ".") .. "/.malleable/home")
  mkdir(dir)
  local agent, got, workers = load_agent(o, dir)
  if not agent then print("home: " .. tostring(got)); love.event.quit(); return end
  local w, why = load_world(dir)
  if why then print("home: " .. tostring(why)) end
  local conversation = agent.speech { world = w, clock = love.timer.getTime, workers = workers }
  H = { conversation = conversation, frames = 0, t0 = love.timer.getTime(), no_voice = o.no_voice }
  H.h = home_lib.new { conversation = conversation, clock = love.timer.getTime,
                       voice_why = o.no_voice and "voice off (--no-voice)" or "loading the voice" }
  H.world = w
  if got:match("%.feature$") then
    H.file_path, H.file_text = got, read_file(got)
    -- the folder the file is in, relative to the workspace, for the files it reads
    local rel = got:sub(1, #dir) == dir and got:sub(#dir + 2) or nil
    H.file_dir = rel and (rel:match("^(.*)/[^/]*$") or "") or ""
    local shown, bad = H.h:set_file(H.file_text)
    if not shown then print("home: the agent file will not show: " .. tostring(bad))
    elseif rel and w.fs then
      local results, vwhy = H.h:verify(w.fs, H.file_dir)
      if not results then print("home: the file's scenarios could not run: " .. tostring(vwhy)) end
    end
  end
  H.h:add("note", "Talking to " .. tostring(agent.spec().name) .. " (" .. got:match("([^/\\]+)$")
    .. "), in " .. dir .. (why and (". " .. why) or "") .. ".")
  if o.script then
    local text = read_file(o.script)
    if not text then print("home: no script at " .. o.script); love.event.quit(); return end
    local lines = {}
    for l in text:gmatch("[^\n]+") do if l:match("%S") and not l:match("^%s*#") then lines[#lines + 1] = l end end
    H.script = { lines = lines, at = 1, t0 = love.timer.getTime() }
  end
  love.update = update
  love.draw = draw
  -- a scripted run is the script's alone: the person's keys and clicks do not reach it
  local person = not H.script
  love.keypressed = function (key) if person then H.h:key(key) end end
  love.textinput = function (t) if person then H.h:text(t) end end
  love.mousepressed = function (x, y, button) if person and button == 1 then H.h:press(x, y) end end
  love.mousemoved = function (x, y) if person then H.h:pointer(x, y) end end
  love.mousefocus = function (inside)
    if person then
      if inside then H.h:pointer(love.mouse.getPosition()) else H.h:pointer(nil) end
    end
  end
  if person and love.window.hasMouseFocus() then H.h:pointer(love.mouse.getPosition()) end
  love.wheelmoved = function (_, wy) H.h:wheel(wy) end
  love.resize = function (w, hgt)
    print(string.format("window %d x %d (%d x %d pixels)", w, hgt, love.graphics.getPixelDimensions()))
  end
end
