-- agent_file — the agent's own feature file, laid out on the stage (docs/spec/agent-file.md).
--
--     local agent_file = require "console.lib.agent_file"
--     local f = agent_file.new()
--     f:set(text)                                  -- the file; nil and why if it will not read
--     f:observed(blocks)                           -- the runs observed so far, at the foot
--     local items, wanted = f:draw(rect, measure, size, now)
--     f:wheel(dy)
--
-- The file is read with gherkin.document, so what is shown is what the agent's own reader
-- reads. It becomes rows, one line each with a key that names its place in the file and a
-- state, and the rows become items in window pixels. The render is a function of the text,
-- the observed runs and the rectangle; `now` only moves what changed since the last frame
-- into place: a line that arrived slides in, one that went fades, one whose state changed
-- takes its colour, and the rest shift by what landed. Nothing here names the host.

local gherkin = require "gherkin"

local agent_file = {}

agent_file.INK   = { 0.90, 0.89, 0.86 }   -- on the home screen's dark stage
agent_file.QUIET = 0.5        -- a keyword's tone, against ink at 1
agent_file.RULE  = { 0.32, 0.32, 0.34 }
agent_file.INDENT = 1.6       -- text sizes one level of indent is
agent_file.LINE   = 1.5       -- text sizes one row is
agent_file.EASE   = 0.2       -- seconds a change takes to land
agent_file.ADDED  = 2         -- seconds a line that landed keeps its mark
agent_file.HUES = {           -- colour is kept for state
  running = { 0.00, 0.64, 1.00 }, waiting = { 1.00, 0.80, 0.10 },
  passed  = { 0.22, 0.80, 0.52 }, failed  = { 1.00, 0.45, 0.20 },
  added   = { 0.22, 0.80, 0.52 },
}

local F = {}
F.__index = F

--- A file with nothing in it yet.
function agent_file.new()
  return setmetatable({ rows_ = {}, obs_rows = {}, scroll = 0, wanted = 0, room = 0,
                        seen = {}, gone = {}, drawn = false }, F)
end

-- Lines of at most `w` pixels, words kept whole unless one is wider than a line.
local function wrap(text, w, measure, size)
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

-- `text` cut to `w` pixels with "..." when it is wider.
local function cut(text, w, measure, size)
  if measure(text, size) <= w then return text end
  local n = #text
  while n > 0 and measure(text:sub(1, n) .. "...", size) > w do n = n - 1 end
  return text:sub(1, n) .. "..."
end

-- A row's key names it by what it says, not where it is, so a line above it can come or go
-- and it is still the same line to the next frame: kind, text, and which repeat of that
-- text it is. `counts` is the file's, fresh for every parse.
local function keyed(counts, prefix, kind, text)
  local base = prefix .. kind .. ":" .. text
  counts[base] = (counts[base] or 0) + 1
  return counts[base] == 1 and base or (base .. "#" .. counts[base])
end

local function tag_row(key, tags, depth)
  local out = {}
  for i, t in ipairs(tags) do out[i] = "@" .. tostring(t):gsub("^@", "") end
  return { key = key, kind = "tag", indent = depth, parts = { { text = table.concat(out, " "), tone = "quiet" } } }
end

-- The rows of one block (a background, a scenario), `depth` levels in. `prefix` names the
-- run for an observed block, and `state` is the block's.
local function block_rows(rows, counts, b, depth, prefix, state)
  if not b then return end
  prefix = prefix or ""
  local keyword = b.kind == "background" and "Background:" or "Scenario:"
  local bkey = keyed(counts, prefix, "block", keyword .. (b.name or ""))
  rows[#rows + 1] = { key = "blank:" .. bkey, kind = "blank", indent = 0, parts = {} }
  if #b.tags > 0 then rows[#rows + 1] = tag_row("tags:" .. bkey, b.tags, depth) end
  rows[#rows + 1] = { key = bkey, kind = "block", indent = depth, state = state,
                      parts = { { text = keyword, tone = "quiet" }, { text = b.name or "", tone = "ink" } } }
  for _, s in ipairs(b.steps) do
    local kw = (s.keyword:gsub("%s+$", ""))
    local skey = keyed(counts, prefix, "step", kw .. " " .. s.text)
    rows[#rows + 1] = { key = skey, kind = "step", indent = depth + 1,
                        parts = { { text = kw, tone = "quiet" }, { text = s.text, tone = "ink" } } }
    if s.doc then
      local i = 0
      for l in (s.doc .. "\n"):gmatch("(.-)\n") do
        i = i + 1
        rows[#rows + 1] = { key = skey .. ":doc:" .. i, kind = "doc", indent = depth + 2,
                            parts = { { text = l, tone = "ink" } } }
      end
    end
    if s.rows then
      for r, cells in ipairs(s.rows) do
        local parts = {}
        for c, cell in ipairs(cells) do parts[c] = { text = tostring(cell), tone = r == 1 and "quiet" or "ink" } end
        rows[#rows + 1] = { key = skey .. ":cells:" .. r, kind = "cells", indent = depth + 2,
                            table = skey, parts = parts }
      end
    end
  end
end

-- The description: the file's own lines between the Feature line and its first block,
-- less the tag lines, as the reader takes them.
local function description(text, doc)
  local first = math.huge
  if doc.background then first = math.min(first, doc.background.line) end
  if doc.scenarios[1] then first = math.min(first, doc.scenarios[1].line) end
  if doc.rules[1] then first = math.min(first, doc.rules[1].line) end
  local out, n = {}, 0
  for l in (text .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n > doc.line and n < first then
      local t = l:gsub("^%s+", ""):gsub("%s+$", "")
      if t:sub(1, 1) ~= "@" then out[#out + 1] = t end
    end
  end
  while #out > 0 and out[1] == "" do table.remove(out, 1) end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end

--- The file's text. Answers true, or nil and why; the last good file stays.
function F:set(text)
  local doc, why = gherkin.document(tostring(text or ""))
  if not doc then return nil, why end
  local rows, counts = {}, {}
  local fkey = "feature:" .. (doc.name or "")
  if #doc.tags > 0 then rows[#rows + 1] = tag_row("tags:" .. fkey, doc.tags, 0) end
  rows[#rows + 1] = { key = fkey, kind = "feature", indent = 0, parts = { { text = doc.name or "", tone = "ink" } } }
  for _, l in ipairs(description(text, doc)) do
    rows[#rows + 1] = { key = keyed(counts, "", "description", l), kind = "description", indent = 0,
                        parts = { { text = l, tone = "ink" } } }
  end
  block_rows(rows, counts, doc.background, 0)
  for _, s in ipairs(doc.scenarios) do block_rows(rows, counts, s, 0) end
  for _, r in ipairs(doc.rules) do
    local rkey = keyed(counts, "", "block", "Rule:" .. (r.name or ""))
    rows[#rows + 1] = { key = "blank:" .. rkey, kind = "blank", indent = 0, parts = {} }
    rows[#rows + 1] = { key = rkey, kind = "block", indent = 0,
                        parts = { { text = "Rule:", tone = "quiet" }, { text = r.name or "", tone = "ink" } } }
    block_rows(rows, counts, r.background, 1)
    for _, s in ipairs(r.scenarios) do block_rows(rows, counts, s, 1) end
  end
  self.rows_ = rows
  self.text = text
  return true
end

--- The runs observed so far, at the foot: each `{ id, text, state, note, parent }`, `text`
--- the scenario as observe writes it, `state` one of running, waiting, passed, failed and
--- folded, `note` a few words a folded run keeps beside its name, and `parent` the id of
--- the run this one was delegated by, under which it nests one level in (a block comes
--- after its parent). A block the reader refuses is shown as its one line with the reason.
function F:observed(blocks)
  local rows, counts, depth = {}, {}, {}
  for _, b in ipairs(blocks or {}) do
    local prefix = tostring(b.id) .. ":"
    local d = b.parent and depth[tostring(b.parent)] and (depth[tostring(b.parent)] + 1) or 0
    depth[tostring(b.id)] = d
    local doc = gherkin.document("Feature: observed\n" .. tostring(b.text or ""))
    local sc = doc and doc.scenarios[1]
    if not sc then
      rows[#rows + 1] = { key = "blank:" .. prefix, kind = "blank", indent = 0, parts = {} }
      rows[#rows + 1] = { key = prefix .. "block:", kind = "block", indent = d, state = b.state,
                          parts = { { text = "Scenario:", tone = "quiet" }, { text = tostring(b.id), tone = "ink" } } }
    elseif b.state == "folded" then
      local bkey = keyed(counts, prefix, "block", "Scenario:" .. (sc.name or ""))
      rows[#rows + 1] = { key = "blank:" .. bkey, kind = "blank", indent = 0, parts = {} }
      rows[#rows + 1] = { key = bkey, kind = "block", indent = d, state = "folded",
                          parts = { { text = "Scenario:", tone = "quiet" }, { text = sc.name or "", tone = "ink" },
                                    { text = b.note or "", tone = "quiet" } } }
    else
      block_rows(rows, counts, sc, d, prefix, b.state)
    end
  end
  self.obs_rows = rows
end

--- What the file's scenarios did when last run: a list of `{ name, outcome, authored }`
--- (src/authoring.lua's verify). A scenario that passed is `passed`, one that did not is
--- `failed`; a proposed one, never scored, keeps no state. Nil clears them all.
function F:results(list)
  local by_name = {}
  for _, r in ipairs(list or {}) do if r.authored ~= false then by_name[r.name] = r.outcome end end
  for _, row in ipairs(self.rows_) do
    if row.kind == "block" and row.parts[1].text == "Scenario:" then
      local got = by_name[row.parts[2].text]
      row.state = got and (got == "passed" and "passed" or "failed") or nil
    end
  end
end

--- The rows of the last good file and the observed runs after it, in order.
function F:rows()
  local out = {}
  for _, r in ipairs(self.rows_) do out[#out + 1] = r end
  for _, r in ipairs(self.obs_rows) do out[#out + 1] = r end
  return out
end

--- A wheel tick: up (dy > 0) or down, three rows each.
function F:wheel(dy)
  local step = 3 * math.floor(14 * agent_file.LINE)
  self.scroll = self.scroll + (dy > 0 and -step or step)
  self:clamp()
end

function F:clamp()
  self.scroll = math.max(0, math.min(self.scroll, math.max(0, self.wanted - self.room)))
end

local function ease(t) t = math.max(0, math.min(1, t)); return 1 - (1 - t) * (1 - t) end

-- Where a seen line is now: eased from where it was to where it goes.
local function at(s, t)
  local k = ease((t - s.moved) / agent_file.EASE)
  return s.from + (s.y - s.from) * k
end

local function blend(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

--- The items for the file inside `rect`, and the height the whole file wants. `now` is
--- seconds; without it, or on the first frame, everything is in place.
function F:draw(rect, measure, size, now)
  local items = {}
  local lh = math.floor(size * agent_file.LINE)
  local unit = math.floor(size * agent_file.INDENT)
  local margin = math.max(size * 2, math.floor(rect.w * 0.06))
  local x0, width = rect.x + margin, rect.w - margin * 2
  local ink = agent_file.INK
  local rows = self:rows()

  -- column positions for each table, from the widest cell in each column
  local columns = {}
  for _, row in ipairs(rows) do
    if row.kind == "cells" then
      local col = columns[row.table] or {}
      columns[row.table] = col
      for c, p in ipairs(row.parts) do col[c] = math.max(col[c] or 0, measure(p.text, size)) end
    end
  end

  -- the lines to draw, before any is placed: a row may take more than one
  local lines = {}
  local function add(row, i, l) l.key = row.key .. "/" .. i; l.state = row.state; l.first = i == 1; lines[#lines + 1] = l end
  for _, row in ipairs(rows) do
    local x = x0 + row.indent * unit
    local room = math.max(size * 4, x0 + width - x)
    if row.kind == "blank" then
      add(row, 1, { h = math.floor(lh * 0.6), parts = {} })
    elseif row.kind == "feature" then
      local big = math.floor(size * 1.5)
      add(row, 1, { h = math.floor(big * agent_file.LINE), size = big,
                    parts = { { text = cut(row.parts[1].text, room, measure, big), x = x, tone = "ink" } } })
    elseif row.kind == "doc" then
      local wrapped = wrap(row.parts[1].text, room, measure, size)
      if #wrapped == 0 then wrapped[1] = "" end
      for i, l in ipairs(wrapped) do
        add(row, i, { h = lh, rule = x - math.floor(unit * 0.5), parts = { { text = l, x = x, tone = "ink" } } })
      end
    elseif row.kind == "cells" then
      local col, parts, cx = columns[row.table], {}, x
      for c, p in ipairs(row.parts) do
        parts[c] = { text = cut(p.text, math.max(size, x0 + width - cx), measure, size), x = cx, tone = p.tone }
        cx = cx + col[c] + unit
      end
      add(row, 1, { h = lh, parts = parts })
    else
      -- a keyword, then text wrapped after it with a hanging indent
      local head, rest, note = row.parts[1], row.parts[2], row.parts[3]
      if not rest then
        for i, l in ipairs(wrap(head.text, room, measure, size)) do
          add(row, i, { h = lh, parts = { { text = l, x = x, tone = head.tone } } })
        end
      else
        local kw = measure(head.text, size) + math.floor(size * 0.5)
        local wrapped = wrap(rest.text, math.max(size * 3, room - kw), measure, size)
        if #wrapped == 0 then wrapped[1] = "" end
        for i, l in ipairs(wrapped) do
          local parts = {}
          if i == 1 then parts[1] = { text = head.text, x = x, tone = head.tone } end
          parts[#parts + 1] = { text = l, x = x + kw, tone = rest.tone }
          if note and i == #wrapped and note.text ~= "" then
            local nx = x + kw + measure(l, size) + math.floor(size * 0.8)
            parts[#parts + 1] = { text = cut(note.text, math.max(size, x0 + width - nx), measure, size), x = nx, tone = note.tone }
          end
          add(row, i, { h = lh, parts = parts })
        end
      end
    end
  end

  local wanted = margin
  for _, l in ipairs(lines) do wanted = wanted + l.h end
  wanted = wanted + margin
  self.wanted, self.room = wanted, rect.h

  -- what changed since the last frame: the seen lines by key, their places and states
  local t = now or 0
  local settling = self.drawn and now ~= nil
  local seen, current = self.seen, {}
  local y = margin
  local landed_below = nil
  for _, l in ipairs(lines) do
    local s = seen[l.key]
    if not s then
      s = { y = y, since = settling and t or -math.huge, state = l.state, state_since = -math.huge, from = y, moved = -math.huge }
      seen[l.key] = s
      if settling and y + l.h > self.scroll + rect.h then landed_below = y + l.h end
    else
      if s.y ~= y then s.from, s.moved, s.y = at(s, t), t, y end
      if s.state ~= l.state then s.was, s.state, s.state_since = s.state, l.state, t end
    end
    current[l.key] = true
    l.seen = s
    y = y + l.h
  end
  for key, s in pairs(seen) do
    if not current[key] then
      if settling then self.gone[#self.gone + 1] = { y = at(s, t), since = t, text = s.text, x = s.x, h = s.h } end
      seen[key] = nil
    end
  end
  self.drawn = true
  if landed_below then self.scroll = landed_below - rect.h + margin end
  self:clamp()

  items[#items + 1] = { kind = "clip", x = rect.x, y = rect.y, w = rect.w, h = rect.h }
  local top = rect.y - self.scroll
  for _, l in ipairs(lines) do
    local s = l.seen
    local ly = top + at(s, t)
    local come = ease((t - s.since) / agent_file.EASE)
    ly = ly + (1 - come) * size * 0.6
    if ly + l.h >= rect.y and ly <= rect.y + rect.h then
      local hue = l.state and agent_file.HUES[l.state]
      local mix = 1
      if s.was ~= nil or s.state_since > -math.huge then mix = ease((t - s.state_since) / agent_file.EASE) end
      local was = s.was and agent_file.HUES[s.was]
      if l.rule then
        items[#items + 1] = { kind = "rect", x = l.rule, y = ly, w = 2, h = l.h, rgb = agent_file.RULE, alpha = come }
      end
      if t - s.since < agent_file.ADDED and s.since > -math.huge then
        local a = 1 - (t - s.since) / agent_file.ADDED
        items[#items + 1] = { kind = "rect", x = rect.x + math.floor(margin * 0.4), y = ly, w = 3, h = l.h,
                              rgb = agent_file.HUES.added, alpha = a * come }
      end
      if (hue or was) and l.first then
        local from = was or ink
        local to = hue or ink
        local c = blend(from, to, mix)
        items[#items + 1] = { kind = "circle", x = rect.x + math.floor(margin * 0.7), y = ly + l.h / 2,
                              r = size * 0.18, rgb = c, alpha = come, segments = 12 }
      end
      for _, p in ipairs(l.parts) do
        local rgb, alpha = ink, p.tone == "quiet" and agent_file.QUIET or 1
        if l.state == "folded" then alpha = agent_file.QUIET
        elseif p.tone == "ink" and (hue or was) then rgb = blend(was or ink, hue or ink, mix) end
        items[#items + 1] = { kind = "text", text = p.text, x = p.x, y = ly, size = l.size or size, rgb = rgb, alpha = alpha * come }
        s.text, s.x, s.h = p.text, p.x, l.h
      end
    end
  end
  -- the lines that went: struck through and fading where they were
  local kept = {}
  for _, g in ipairs(self.gone) do
    local a = 1 - ease((t - g.since) / agent_file.EASE)
    if a > 0.02 and g.text then
      local gy = top + g.y
      items[#items + 1] = { kind = "text", text = g.text, x = g.x, y = gy, size = size, rgb = ink, alpha = a * 0.6 }
      items[#items + 1] = { kind = "rect", x = g.x, y = gy + g.h / 2, w = measure(g.text, size), h = 1, rgb = ink, alpha = a * 0.6 }
      kept[#kept + 1] = g
    end
  end
  self.gone = kept
  items[#items + 1] = { kind = "unclip" }
  return items, wanted
end

return agent_file
