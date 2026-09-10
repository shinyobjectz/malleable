-- work: the two records that make a long run trustworthy.
--
-- A PLAN is the ordered list of items an agent states before it acts and marks off as
-- it goes, rendered as one plain block for the person and for the model. A CHECKPOINT
-- is the exact contents of the files a turn is about to touch, captured before the
-- edit, so the turn can be taken back. Undo restores those bytes; it does not merge,
-- diff or reconcile, and anything written to a captured path afterwards is gone.
--
-- Two rules shape every function here.
--
--   * A wrong argument type RAISES -- it is a bug in the calling code and it should
--     stop at the line that made it. A bad world RETURNS nil plus a reason string.
--     Nothing here ever answers false.
--   * The world is reached only through the fs slice of the port table: read, write,
--     remove, exists. No clock, no shell, no model, no approval channel, no store.
--     Checkpoint ids come from a counter, so two runs of a test agree byte for byte.
--
-- The one deliberate exception is work.undo, which always answers with a report and
-- never with nil: an abandoned half-restore leaves a workspace that matches neither
-- the checkpoint nor the turn, which is worse than a report that is honest about it.
--
-- This file stands alone. It names no sibling module and holds no module-level
-- mutable state, so two plans and two trails in one process share nothing.

local work = {}

local fmt = string.format

-- ------------------------------------------------------------------ the constants

-- Kept privately as well as published, so a caller that writes into the published
-- copy changes nothing but its own view.
local STATES  = { "todo", "doing", "done", "dropped" }
local IS_STATE = { todo = true, doing = true, done = true, dropped = true }
local MARKS   = { todo = "[ ]", doing = "[>]", done = "[x]", dropped = "[-]" }
local STATE_LIST = "todo, doing, done, dropped"

local LIMITS = {
  max_items = 32,
  max_text  = 400,
  max_files = 64,
  max_bytes = 4194304,
  cap       = 8,
}

-- A trail holds more than one full-sized checkpoint by default, so the turn before
-- last is still undoable after a large edit.
local TRAIL_BYTES = 8388608

-- The two published tables are read-only, by the strongest means each shape allows in
-- both dialects this tree targets.
--
-- `defaults` is read by key, so it is a proxy over hidden values and every write to it
-- raises. `states` is read with `#` and ipairs, and LuaJIT 5.1 answers neither __len
-- nor __index for those, so a proxy would make `#work.states` zero on one of the two
-- interpreters. It is a real list instead: a new key raises, while overwriting one of
-- the four slots is not catchable and changes nothing but the caller's own view, since
-- this module reads its own copy.
local function sealed(values, what)
  return setmetatable({}, {
    __index = values,
    __newindex = function ()
      error(what .. " is read-only; pass the limit you want per call", 2)
    end,
    __metatable = what,
  })
end

work.states = setmetatable({ STATES[1], STATES[2], STATES[3], STATES[4] }, {
  __newindex = function ()
    error("work.states is read-only; it is the closed set of the four states", 2)
  end,
  __metatable = "work.states",
})

work.defaults = sealed({
  max_items = LIMITS.max_items,
  max_text  = LIMITS.max_text,
  max_files = LIMITS.max_files,
  max_bytes = LIMITS.max_bytes,
  cap       = LIMITS.cap,
}, "work.defaults")

-- ------------------------------------------------------------------ small helpers

-- Level 3: the sentence points at the line that made the mistake, not at this file.
local function raise(what, ...)
  error(fmt(what, ...), 3)
end

local function is_list(v)
  if type(v) ~= "table" then return false end
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
    n = n + 1
  end
  return n == #v
end

local function is_plan(v)
  return type(v) == "table"
     and type(v.items) == "table"
     and type(v.revision) == "number"
     and type(v.seq) == "number"
end

local function bound(where, name, v)
  if v == nil then return nil end
  if type(v) ~= "number" or v ~= math.floor(v) or v < 1 then
    error(fmt("%s: `%s` is a whole number of at least 1, got %s", where, name, tostring(v)), 3)
  end
  return v
end

local function opts_table(where, opts)
  if opts == nil then return {} end
  if type(opts) ~= "table" then
    error(fmt("%s: `opts` is nil or a table, got %s", where, type(opts)), 3)
  end
  return opts
end

-- Everything a plan holds is bytes a model wrote, and a rendered block promises bytes
-- below 128 so it survives any transport a host puts it through. Anything outside the
-- plain ASCII range becomes a question mark at render time only: the item keeps the
-- bytes it was given.
local function plain(s)
  return (tostring(s):gsub("[^\32-\126]", "?"))
end

-- ------------------------------------------------------------------- plan building

-- One entry, checked. Returns a prepared item without an id, or nil and the reason.
local function read_entry(i, entry, max_text)
  local text, id, state, note
  if type(entry) == "string" then
    text = entry
  elseif type(entry) == "table" then
    text, id, state, note = entry.text, entry.id, entry.state, entry.note
  else
    return nil, fmt("item %d is a %s, and an item is a string or a table", i, type(entry))
  end

  if type(text) ~= "string" then
    if text == nil then return nil, fmt("item %d has no text", i) end
    return nil, fmt("item %d: text is a %s, not a string", i, type(text))
  end
  if text == "" then return nil, fmt("item %d has empty text", i) end
  if #text > max_text then
    return nil, fmt("item %d: text is %d bytes, over the limit of %d", i, #text, max_text)
  end
  if text:find("\n", 1, true) or text:find("\r", 1, true) then
    return nil, fmt("item %d: text holds a newline, and an item is one line", i)
  end

  if id ~= nil then
    if type(id) ~= "string" then
      return nil, fmt("item %d: id is a %s, not a string", i, type(id))
    end
    if id == "" then return nil, fmt("item %d has an empty id", i) end
  end

  if state ~= nil then
    if type(state) ~= "string" or not IS_STATE[state] then
      return nil, fmt("item %d: %s is not one of %s", i, tostring(state), STATE_LIST)
    end
  end

  if note ~= nil then
    if type(note) ~= "string" then
      return nil, fmt("item %d: note is a %s, not a string", i, type(note))
    end
    if #note > max_text then
      return nil, fmt("item %d: note is %d bytes, over the limit of %d", i, #note, max_text)
    end
  end

  return { id = id, text = text, state = state, note = note }
end

-- Build the whole replacement list before a single field of the plan is written, so a
-- rejected replacement leaves the plan exactly as it was.
--
--   known  -- id -> the item the plan currently holds, or nil for a fresh plan
--   seq    -- where minting starts; it only ever goes up, so an id in an old render
--             never comes to mean a different item later
local function build(entries, known, seq, max_items, max_text)
  local n = #entries
  if n > max_items then
    return nil, fmt("%d items is over the limit of %d", n, max_items)
  end

  local read, given = {}, {}
  for i = 1, n do
    local item, reason = read_entry(i, entries[i], max_text)
    if item == nil then return nil, reason end
    if item.id ~= nil then
      if given[item.id] then
        return nil, fmt("item %d repeats the id %s, and an id names one item", i, item.id)
      end
      given[item.id] = i
    end
    read[i] = item
  end

  -- An id the plan currently holds keeps its item's marks; anything else is new and
  -- is minted, never recycled.
  local taken, out = {}, {}
  for i = 1, n do
    local item = read[i]
    local held = (item.id ~= nil and known ~= nil) and known[item.id] or nil
    local id, state, note
    if held ~= nil then
      id = item.id
      if item.text == held.text then
        state, note = held.state, held.note
      else
        state, note = "todo", nil     -- a different item wearing an old label
      end
    elseif item.id ~= nil and known == nil then
      id = item.id                    -- a fresh plan honours the ids it was handed
    end
    -- An explicit mark in the entry is what the caller asked for and wins over both.
    if item.state ~= nil then state = item.state end
    if item.note ~= nil then note = item.note end
    if id ~= nil then taken[id] = true end
    out[i] = { id = id, text = item.text, state = state or "todo", note = note }
  end

  for i = 1, n do
    if out[i].id == nil then
      while taken[tostring(seq)] do seq = seq + 1 end
      out[i].id = tostring(seq)
      taken[out[i].id] = true
      seq = seq + 1
    end
  end

  -- Keep the counter past every id in the list, so a dropped id is never handed out
  -- a second time.
  for i = 1, n do
    local number = out[i].id:match("^%d+$")
    if number then
      local v = tonumber(number)
      if v ~= nil and v >= seq then seq = v + 1 end
    end
  end

  local flight
  for i = 1, n do
    if out[i].state == "doing" then
      if flight then
        return nil, fmt("item %d is a second item in flight; item %d is already doing", i, flight)
      end
      flight = i
    end
  end

  return out, seq
end

function work.plan(entries, opts)
  if not is_list(entries) then
    -- A table that is not a list is the shape a decoded JSON object arrives in, and
    -- reading it as an empty list would answer "no items" to a caller that sent some.
    raise("work.plan: `items` is a list of items, got %s",
          type(entries) == "table" and "a table that is not a list" or type(entries))
  end
  opts = opts_table("work.plan", opts)
  local max_items = bound("work.plan", "max_items", opts.max_items) or LIMITS.max_items
  local max_text  = bound("work.plan", "max_text",  opts.max_text)  or LIMITS.max_text

  local items, seq = build(entries, nil, 1, max_items, max_text)
  if items == nil then return nil, seq end
  return { items = items, revision = 1, seq = seq }
end

function work.set(plan, entries, opts)
  if not is_plan(plan) then
    raise("work.set: `plan` is a plan table, got %s", type(plan))
  end
  if not is_list(entries) then
    raise("work.set: `items` is a list of items, got %s",
          type(entries) == "table" and "a table that is not a list" or type(entries))
  end
  opts = opts_table("work.set", opts)
  local max_items = bound("work.set", "max_items", opts.max_items) or LIMITS.max_items
  local max_text  = bound("work.set", "max_text",  opts.max_text)  or LIMITS.max_text

  local known = {}
  for i = 1, #plan.items do
    local item = plan.items[i]
    known[item.id] = item
  end

  local items, seq = build(entries, known, plan.seq, max_items, max_text)
  if items == nil then return nil, seq end

  plan.items = items
  plan.seq = seq
  plan.revision = plan.revision + 1
  return plan
end

local function find(plan, id)
  for i = 1, #plan.items do
    if plan.items[i].id == id then return plan.items[i] end
  end
  return nil
end

local function in_flight(plan, except)
  for i = 1, #plan.items do
    local item = plan.items[i]
    if item.state == "doing" and item ~= except then return item end
  end
  return nil
end

function work.mark(plan, id, state, note, opts)
  if not is_plan(plan) then
    raise("work.mark: `plan` is a plan table, got %s", type(plan))
  end
  if type(id) ~= "string" then
    raise("work.mark: `id` is an item's id, as a string, got %s -- an index is not an id", type(id))
  end
  if type(state) ~= "string" or not IS_STATE[state] then
    raise("work.mark: `state` is one of %s, got %s", STATE_LIST, tostring(state))
  end
  if note ~= nil and type(note) ~= "string" then
    raise("work.mark: `note` is a string or nil, got %s", type(note))
  end
  opts = opts_table("work.mark", opts)
  local max_text = bound("work.mark", "max_text", opts.max_text) or LIMITS.max_text

  local item = find(plan, id)
  if item == nil then
    return nil, fmt("no item with the id %s", id)
  end
  if note ~= nil and #note > max_text then
    return nil, fmt("the note is %d bytes, over the limit of %d", #note, max_text)
  end
  if state == "doing" then
    local busy = in_flight(plan, item)
    if busy ~= nil then
      return nil, fmt("item %s is already doing; start displaces it, mark does not", busy.id)
    end
  end

  item.state = state
  item.note = note
  plan.revision = plan.revision + 1
  return item
end

function work.start(plan, id)
  if not is_plan(plan) then
    raise("work.start: `plan` is a plan table, got %s", type(plan))
  end
  if type(id) ~= "string" then
    raise("work.start: `id` is an item's id, as a string, got %s", type(id))
  end

  local item = find(plan, id)
  if item == nil then
    return nil, fmt("no item with the id %s", id)
  end
  if item.state == "doing" then
    return item, nil
  end

  local busy = in_flight(plan, item)
  local displaced
  if busy ~= nil then
    busy.state = "todo"
    displaced = busy.id
  end
  item.state = "doing"
  plan.revision = plan.revision + 1
  return item, displaced
end

function work.next(plan)
  if not is_plan(plan) then
    raise("work.next: `plan` is a plan table, got %s", type(plan))
  end
  for i = 1, #plan.items do
    if plan.items[i].state == "doing" then return plan.items[i] end
  end
  for i = 1, #plan.items do
    if plan.items[i].state == "todo" then return plan.items[i] end
  end
  return nil
end

function work.progress(plan)
  if not is_plan(plan) then
    raise("work.progress: `plan` is a plan table, got %s", type(plan))
  end
  local done, total, doing = 0, 0, nil
  for i = 1, #plan.items do
    local item = plan.items[i]
    if item.state ~= "dropped" then total = total + 1 end
    if item.state == "done" then done = done + 1 end
    if item.state == "doing" then doing = item.id end
  end
  return done, total, doing
end

-- Total by design: a render is what a person is looking at when something has already
-- gone wrong, so it renders a state it does not know as [?] rather than raising.
function work.render(plan, opts)
  local heading, with_ids = "Plan", true
  if type(opts) == "table" then
    if type(opts.heading) == "string" then heading = opts.heading end
    if opts.ids == false then with_ids = false end
  end

  local items = (type(plan) == "table" and type(plan.items) == "table") and plan.items or {}
  local n = #items
  local done = 0
  for i = 1, n do
    if type(items[i]) == "table" and items[i].state == "done" then done = done + 1 end
  end

  -- The denominator counts every item in the block, including a dropped one, because
  -- a reader can count the lines under it. work.progress answers the other question,
  -- and leaves a dropped item out of its total.
  local out = { fmt("%s (%d/%d)", plain(heading), done, n) }
  if n == 0 then
    out[2] = "  (no items)"
  else
    for i = 1, n do
      local item = items[i]
      if type(item) ~= "table" then item = { id = tostring(i), text = tostring(item) } end
      local line = "  "
      if with_ids then line = line .. plain(item.id or i) .. ". " end
      line = line .. (MARKS[item.state] or "[?]") .. " " .. plain(item.text or "")
      if type(item.note) == "string" and item.note ~= "" then
        line = line .. " -- " .. plain(item.note)
      end
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------- the port slice

local FS_CALLS = { "read", "write", "remove", "exists" }

-- A checkpoint is taken so that it can be undone, so a port that cannot write or
-- remove is refused at the take, not discovered at the restore.
local function need_fs(where, p)
  if type(p) ~= "table" then
    error(fmt("%s: `port` is a table carrying an fs slice, got %s", where, type(p)), 3)
  end
  local fs = p.fs
  if type(fs) ~= "table" then
    error(fmt("%s: `port.fs` is a table, got %s", where, type(fs)), 3)
  end
  for i = 1, #FS_CALLS do
    local name = FS_CALLS[i]
    if type(fs[name]) ~= "function" then
      error(fmt("%s: `port.fs.%s` is a function, got %s", where, name, type(fs[name])), 3)
    end
  end
  return fs
end

-- The port's own error table is carried through untouched. Anything else -- a port
-- that returned a bare string, or one that raised -- is wrapped in the same shape so
-- a caller has one thing to read.
local function as_err(call, value)
  if type(value) == "table" and type(value.code) == "string" then return value end
  return { port = "fs", call = call, code = "malformed", message = tostring(value) }
end

local function reason_of(err)
  if type(err) == "table" then
    if type(err.message) == "string" then return err.message end
    if type(err.code) == "string" then return err.code end
  end
  return tostring(err)
end

-- ------------------------------------------------------------------- checkpoints

function work.take(p, paths, opts)
  local fs = need_fs("work.take", p)
  if not is_list(paths) then
    raise("work.take: `paths` is a list of workspace-relative strings, got %s", type(paths))
  end
  opts = opts_table("work.take", opts)
  if opts.label ~= nil and type(opts.label) ~= "string" then
    raise("work.take: `opts.label` is a string, got %s", type(opts.label))
  end
  local max_files = bound("work.take", "max_files", opts.max_files) or LIMITS.max_files
  local max_bytes = bound("work.take", "max_bytes", opts.max_bytes) or LIMITS.max_bytes

  -- Copy before sorting: the caller's list is not this module's to reorder.
  local seen, want = {}, {}
  for i = 1, #paths do
    local path = paths[i]
    if type(path) ~= "string" or path == "" then
      raise("work.take: path %d is a non-empty string, got %s", i, type(path))
    end
    if not seen[path] then
      seen[path] = true
      want[#want + 1] = path
    end
  end
  table.sort(want)

  if #want > max_files then
    return nil, fmt("%d paths is over the limit of %d", #want, max_files), {}
  end

  local files, misses, bytes = {}, {}, 0
  for i = 1, #want do
    local path = want[i]
    local ok, text, err = pcall(fs.read, path)
    if not ok then
      misses[#misses + 1] = { path = path, err = as_err("read", text) }
    elseif text ~= nil then
      if type(text) ~= "string" then
        misses[#misses + 1] = { path = path, err = as_err("read", "read answered with a " .. type(text)) }
      else
        bytes = bytes + #text
        if bytes > max_bytes then
          return nil, fmt("%s crossed the byte cap: %d bytes captured, over the limit of %d",
                          path, bytes, max_bytes), {}
        end
        files[#files + 1] = { path = path, text = text, existed = true }
      end
    elseif type(err) == "table" and err.code == "not_found" then
      -- The commonest checkpoint there is: the turn is about to create this file.
      files[#files + 1] = { path = path, text = nil, existed = false }
    else
      misses[#misses + 1] = { path = path, err = as_err("read", err) }
    end
  end

  -- A checkpoint that captured four files out of five cannot restore the fifth, so a
  -- partial capture is not a capture.
  if #misses > 0 then
    return nil, fmt("%d of %d paths could not be read, the first is %s",
                    #misses, #want, misses[1].path), misses
  end

  return {
    id      = nil,
    label   = opts.label or "",
    files   = files,
    bytes   = bytes,
    count   = #files,
  }
end

-- Every entry is checked here, before the first byte is written, because a raise from
-- the middle of a restore leaves a workspace that matches neither the checkpoint nor
-- the turn -- the one state work.undo exists to prevent.
local function need_cp(where, cp)
  if type(cp) ~= "table" or type(cp.files) ~= "table" then
    error(fmt("%s: `cp` is a checkpoint table with a `files` list, got %s", where, type(cp)), 3)
  end
  local files = cp.files
  for i = 1, #files do
    local entry = files[i]
    if type(entry) ~= "table" then
      error(fmt("%s: file %d of the checkpoint is a %s, not a table", where, i, type(entry)), 3)
    end
    if type(entry.path) ~= "string" or entry.path == "" then
      error(fmt("%s: file %d of the checkpoint has no path", where, i), 3)
    end
  end
  return files
end

function work.undo(p, cp)
  local fs = need_fs("work.undo", p)
  local files = need_cp("work.undo", cp)

  local report = { restored = 0, removed = 0, skipped = 0, failed = {}, complete = true }

  local function failed(path, why)
    report.failed[#report.failed + 1] = { path = path, reason = why }
    report.complete = false
  end

  for i = 1, #files do
    local entry = files[i]
    local path = entry.path
    if entry.existed then
      if type(entry.text) ~= "string" then
        failed(path, "the checkpoint holds no text for a file it says existed")
      else
        local ok, done, err = pcall(fs.write, path, entry.text)
        if not ok then
          failed(path, tostring(done))
        elseif done then
          report.restored = report.restored + 1
        else
          failed(path, reason_of(err))
        end
      end
    else
      local ok, there = pcall(fs.exists, path)
      if not ok then
        failed(path, tostring(there))
      elseif there then
        local gone, done, err = pcall(fs.remove, path)
        if not gone then
          failed(path, tostring(done))
        elseif done then
          report.removed = report.removed + 1
        else
          failed(path, reason_of(err))
        end
      else
        report.skipped = report.skipped + 1
      end
    end
  end

  return report
end

function work.changed(p, cp)
  local fs = need_fs("work.changed", p)
  local files = need_cp("work.changed", cp)

  local changed, unknown = {}, {}
  for i = 1, #files do
    local entry = files[i]
    local path = entry.path
    local ok, text, err = pcall(fs.read, path)
    if not ok then
      unknown[#unknown + 1] = path
    elseif type(text) == "string" then
      if not entry.existed or text ~= entry.text then
        changed[#changed + 1] = path
      end
    elseif text == nil and type(err) == "table" and err.code == "not_found" then
      if entry.existed then changed[#changed + 1] = path end
    else
      -- A path that cannot be read is unknown, never unchanged: an undo preview
      -- that counted it clean would understate what is about to be overwritten.
      unknown[#unknown + 1] = path
    end
  end
  return changed, unknown
end

function work.describe(cp)
  if type(cp) ~= "table" then
    raise("work.describe: `cp` is a checkpoint table, got %s", type(cp))
  end
  local id = (type(cp.id) == "string" and cp.id ~= "") and plain(cp.id) or "(unfiled)"
  local head = id
  local label = type(cp.label) == "string" and plain(cp.label) or ""
  if label ~= "" then head = head .. ' "' .. label .. '"' end

  local count = cp.count
  if type(count) ~= "number" then count = type(cp.files) == "table" and #cp.files or 0 end
  local bytes = type(cp.bytes) == "number" and cp.bytes or 0

  return fmt("%s -- %d %s, %d %s",
             head,
             count, count == 1 and "file" or "files",
             bytes, bytes == 1 and "byte" or "bytes")
end

-- ------------------------------------------------------------------------ the trail

function work.trail(opts)
  opts = opts_table("work.trail", opts)
  local cap = bound("work.trail", "cap", opts.cap) or LIMITS.cap
  local max_bytes = bound("work.trail", "max_bytes", opts.max_bytes) or TRAIL_BYTES
  return { items = {}, cap = cap, max_bytes = max_bytes, seq = 1, bytes = 0 }
end

local function is_trail(v)
  return type(v) == "table"
     and type(v.items) == "table"
     and type(v.cap) == "number"
     and type(v.max_bytes) == "number"
     and type(v.seq) == "number"
     and type(v.bytes) == "number"
end

local function bytes_of(cp)
  return type(cp.bytes) == "number" and cp.bytes or 0
end

function work.push(trail, cp)
  if not is_trail(trail) then
    raise("work.push: `trail` is a trail table, got %s", type(trail))
  end
  need_cp("work.push", cp)

  if cp.id == nil then
    cp.id = "cp" .. trail.seq
    trail.seq = trail.seq + 1
  elseif type(cp.id) ~= "string" then
    raise("work.push: the checkpoint's id is a string or nil, got %s", type(cp.id))
  else
    -- A checkpoint filed by another trail arrives already named. Keep the counter past
    -- it, so this trail can never mint that name a second time and hold two turns a
    -- host cannot tell apart.
    local number = cp.id:match("^cp(%d+)$")
    local v = number and tonumber(number)
    if v ~= nil and v >= trail.seq then trail.seq = v + 1 end
  end

  trail.items[#trail.items + 1] = cp
  trail.bytes = trail.bytes + bytes_of(cp)

  -- Evict from the oldest end. A single checkpoint over the byte bound on its own is
  -- kept anyway, over the bound and visibly so in trail.bytes: the turn about to
  -- rewrite a large file is the turn most worth being able to undo.
  local evicted = {}
  while #trail.items > 0
    and (#trail.items > trail.cap or (trail.bytes > trail.max_bytes and #trail.items > 1)) do
    local gone = table.remove(trail.items, 1)
    trail.bytes = trail.bytes - bytes_of(gone)
    if trail.bytes < 0 then trail.bytes = 0 end
    evicted[#evicted + 1] = gone
  end

  return trail, evicted
end

function work.last(trail)
  if not is_trail(trail) then
    raise("work.last: `trail` is a trail table, got %s", type(trail))
  end
  return trail.items[#trail.items]
end

function work.pop(trail)
  if not is_trail(trail) then
    raise("work.pop: `trail` is a trail table, got %s", type(trail))
  end
  local cp = table.remove(trail.items)
  if cp == nil then return nil end
  trail.bytes = trail.bytes - bytes_of(cp)
  if trail.bytes < 0 then trail.bytes = 0 end
  return cp
end

function work.undo_last(p, trail)
  need_fs("work.undo_last", p)
  if not is_trail(trail) then
    raise("work.undo_last: `trail` is a trail table, got %s", type(trail))
  end
  local cp = work.pop(trail)
  if cp == nil then return nil, "the trail is empty" end
  return work.undo(p, cp)
end

-- ------------------------------------------------------------------- the two tools

local TOOLS = { plan = true, mark = true }
local INSTALL_KEYS = { plan = true, names = true, on_change = true, max_items = true, max_text = true }

local AGENT_CALLS = { "tool", "list", "string", "string_opt" }

-- A host's renderer must not be able to fail a tool call, so its answer and anything
-- it raises are both discarded.
local function announce(on_change, plan)
  if on_change ~= nil then pcall(on_change, plan) end
end

function work.install(agent, opts)
  if type(agent) ~= "table" then
    raise("work.install: `agent` is the public prefix table, got %s", type(agent))
  end
  for i = 1, #AGENT_CALLS do
    local name = AGENT_CALLS[i]
    if type(agent[name]) ~= "function" then
      raise("work.install: `agent.%s` is a function, got %s", name, type(agent[name]))
    end
  end
  opts = opts_table("work.install", opts)
  for k in pairs(opts) do
    if not INSTALL_KEYS[k] then
      raise("work.install: %s is not one of plan, names, on_change, max_items, max_text", tostring(k))
    end
  end
  if opts.on_change ~= nil and type(opts.on_change) ~= "function" then
    raise("work.install: `on_change` is a function or nil, got %s", type(opts.on_change))
  end
  if opts.plan ~= nil and not is_plan(opts.plan) then
    raise("work.install: `plan` is a plan table, got %s", type(opts.plan))
  end

  local names = { plan = "plan", mark = "mark" }
  if opts.names ~= nil then
    if type(opts.names) ~= "table" then
      raise("work.install: `names` is a table, got %s", type(opts.names))
    end
    for k, v in pairs(opts.names) do
      if not TOOLS[k] then
        raise("work.install: %s is not a tool this declares; there are two, plan and mark, and there is no undo tool", tostring(k))
      end
      if type(v) ~= "string" or v == "" then
        raise("work.install: the name for %s is a non-empty string, got %s", k, type(v))
      end
      names[k] = v
    end
  end

  local max_items = bound("work.install", "max_items", opts.max_items) or LIMITS.max_items
  local max_text  = bound("work.install", "max_text",  opts.max_text)  or LIMITS.max_text
  local limits = { max_items = max_items, max_text = max_text }

  local live = opts.plan
  if live == nil then live = work.plan {} end
  local on_change = opts.on_change

  agent.tool(names.plan) {
    about = "State the whole plan, or replace it. Send every item every time: what is "
         .. "not sent is dropped. Keep an item's id to keep its state; leave the id off "
         .. "for a new item. The answer is the plan as it now stands.",
    args = {
      items = agent.list("the plan in order: each entry a one-line string, or a table "
                      .. "of id, text, state and note"),
    },
    run = function (c)
      local entries = c.args and c.args.items
      -- A model that sent an object rather than an array is told so. Reading it as an
      -- empty list would answer "no items" and quietly throw the plan away.
      if not is_list(entries) then
        return "items is a list of plan items\n" .. work.render(live)
      end
      local ok, reason = work.set(live, entries, limits)
      if ok == nil then
        return reason .. "\n" .. work.render(live)
      end
      announce(on_change, live)
      return work.render(live)
    end,
  }

  agent.tool(names.mark) {
    about = "Mark one item of the plan by its id. Marking an item doing puts back "
         .. "whatever was doing before. The answer is the plan as it now stands.",
    args = {
      id    = agent.string("the item's id, as it appears in the rendered plan"),
      state = agent.string("one of " .. STATE_LIST),
      note  = agent.string_opt("one sentence saying why, kept beside the item"),
    },
    run = function (c)
      local args = c.args or {}
      local id, state, note = args.id, args.state, args.note
      if type(id) ~= "string" or id == "" then
        return "id is an item's id, as a string\n" .. work.render(live)
      end
      if type(state) ~= "string" or not IS_STATE[state] then
        return fmt("%s is not one of %s\n%s", tostring(state), STATE_LIST, work.render(live))
      end
      if note ~= nil and type(note) ~= "string" then
        return "note is a sentence, as a string\n" .. work.render(live)
      end
      if note ~= nil and #note > max_text then
        return fmt("the note is %d bytes, over the limit of %d\n%s", #note, max_text, work.render(live))
      end

      local item, reason
      if state == "doing" then
        -- start takes no note, so the note of the mark is attached here. It is a
        -- change like any other, so the revision moves for it even when start itself
        -- was a no-op on an item already in flight.
        local was = live.revision
        item, reason = work.start(live, id)
        if item ~= nil then
          if item.note ~= note and live.revision == was then
            live.revision = live.revision + 1
          end
          item.note = note
        end
      else
        item, reason = work.mark(live, id, state, note, limits)
      end
      if item == nil then
        return reason .. "\n" .. work.render(live)
      end
      announce(on_change, live)
      return work.render(live)
    end,
  }

  return { plan = live, tools = { plan = names.plan, mark = names.mark } }
end

return work
