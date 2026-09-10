-- tools_fs — the six filesystem tools, declared through the ordinary `agent.tool`
-- surface: read, write, edit, list, glob, search.
--
-- Nothing here touches a real disk. Every call goes through the filesystem port
-- (spec/port.md): `fs.read`, `fs.write`, `fs.list`, `fs.exists`, all of them taking a
-- workspace-relative path and answering `nil, err` for anything the world can do.
-- Give the tools a table of strings for a port and they cannot tell the difference.
--
-- Two shapes, and only two, come back from a tool body:
--
--     { ok = true,  ... }                       -- the fields each tool documents
--     { ok = false, code = "<slug>", reason = "<one sentence>" }
--
-- A refusal is a result the model reads, never a raised error. The one place this
-- module raises is `install`, where a wrong option is a bug in the host's own file and
-- must stop the process rather than become a sentence a model tries to work around.

local tools_fs = {}

local MAX_LINE      = 400    -- a search hit is cut to this many bytes
local SNIFF         = 8000   -- how far in we look for a zero byte before calling it binary
local HINT          = 120    -- how much of a near-miss line the refusal quotes
local ITEMS         = 10     -- how many line numbers an ambiguous edit names

-- ------------------------------------------------------------------ small helpers

local function is_whole(v)
  return type(v) == "number"
     and v == v
     and v ~= math.huge and v ~= -math.huge
     and v == math.floor(v)
end

local function positive_whole(v)
  return is_whole(v) and v > 0
end

local function segments(s)
  local out, i = {}, 1
  while true do
    local j = string.find(s, "/", i, true)
    if not j then
      out[#out + 1] = string.sub(s, i)
      return out
    end
    out[#out + 1] = string.sub(s, i, j - 1)
    i = j + 1
  end
end

local function join(dir, name)
  if dir == "" then return name end
  return dir .. "/" .. name
end

local function parent_of(rel)
  local at = nil
  for i = #rel, 1, -1 do
    if string.sub(rel, i, i) == "/" then at = i break end
  end
  if not at then return "", rel end
  return string.sub(rel, 1, at - 1), string.sub(rel, at + 1)
end

-- A zero byte in the first `SNIFF` bytes is how a file says it is not text.
local function looks_binary(text)
  return string.find(string.sub(text, 1, SNIFF), "\0", 1, true) ~= nil
end

-- The byte offset each line starts at, plus the count. A file's last line is the run
-- after the final newline, and it counts only when it holds something.
local function line_starts(text)
  local starts, i = { 1 }, 1
  while true do
    local j = string.find(text, "\n", i, true)
    if not j then break end
    starts[#starts + 1] = j + 1
    i = j + 1
  end
  local n = #starts
  if starts[n] > #text then n = n - 1 end  -- nothing after the last newline
  return starts, n
end

-- ------------------------------------------------------------------ the pure four

-- Lexical, and only lexical: it never calls the port and never touches a disk, so a
-- path that leaves the workspace is refused before the host is asked anything at all.
-- Returns `abs, rel` on success; `nil, code, reason, extra` on a refusal.
function tools_fs.resolve(root, path)
  if type(path) ~= "string" then
    return nil, "bad_args", "`path` is a workspace-relative string, and arrived as " .. type(path) .. "."
  end
  root = type(root) == "string" and root or ""
  root = (string.gsub(root, "/+$", ""))

  if string.find(path, "\0", 1, true) then
    return nil, "outside_workspace", "the path holds a zero byte, which no filename does; name a plain workspace-relative path."
  end
  if string.sub(path, 1, 1) == "/" or string.match(path, "^%a:") then
    local extra = nil
    if root ~= "" and string.sub(path, 1, #root + 1) == root .. "/" then
      extra = { suggest = (string.gsub(string.sub(path, #root + 2), "^/+", "")) }
    end
    local reason = "the path is absolute, and every path here is relative to the workspace root."
    if extra then reason = reason .. " That file is " .. extra.suggest .. " from the root." end
    return nil, "outside_workspace", reason, extra
  end

  local out = {}
  local segs = segments(path)
  for i = 1, #segs do
    local s = segs[i]
    if s == "" or s == "." then                 -- an empty run and `.` say nothing
    elseif s == ".." then
      if #out == 0 then
        return nil, "outside_workspace", "the path climbs above the workspace root with `..`; name a path inside the workspace."
      end
      out[#out] = nil
    else
      out[#out + 1] = s
    end
  end

  local rel = table.concat(out, "/")
  local abs
  if root == "" then abs = rel
  elseif rel == "" then abs = root
  else abs = root .. "/" .. rel end
  return abs, rel
end

-- A character class: `[abc]`, `[a-z]`, `[!a-z]`, `[^a-z]`, and `]` first is literal.
-- Returns the class and the index just past its `]`, or nil when it is unterminated.
local function parse_class(pat, i)
  local j = i + 1
  local negate = false
  local c = string.sub(pat, j, j)
  if c == "!" or c == "^" then negate = true j = j + 1 end
  local items, first = {}, true
  while true do
    local ch = string.sub(pat, j, j)
    if ch == "" then return nil end
    if ch == "]" and not first then break end
    first = false
    if string.sub(pat, j + 1, j + 1) == "-" then
      local hi = string.sub(pat, j + 2, j + 2)
      if hi ~= "" and hi ~= "]" then
        items[#items + 1] = { lo = ch, hi = hi }
        j = j + 3
      else
        items[#items + 1] = { lo = ch, hi = ch }
        j = j + 1
      end
    else
      items[#items + 1] = { lo = ch, hi = ch }
      j = j + 1
    end
  end
  return { negate = negate, items = items }, j + 1
end

-- One pattern segment, compiled to items: a literal byte, `?`, `*`, or a class.
-- Compiling first is what lets the matcher below be a plain loop with one backtrack
-- point instead of a recursion that branches at every `*`.
local function compile_seg(pat)
  local items, i = {}, 1
  while i <= #pat do
    local c = string.sub(pat, i, i)
    if c == "*" then
      local last = items[#items]
      if last == nil or last.kind ~= "star" then
        items[#items + 1] = { kind = "star" }      -- a run of `*` is one `*`
      end
      i = i + 1
    elseif c == "?" then
      items[#items + 1] = { kind = "any" }
      i = i + 1
    elseif c == "[" then
      local cls, past = parse_class(pat, i)
      if cls then
        items[#items + 1] = { kind = "class", cls = cls }
        i = past
      else
        items[#items + 1] = { kind = "lit", ch = "[" }   -- an unclosed `[` is a byte
        i = i + 1
      end
    else
      items[#items + 1] = { kind = "lit", ch = c }
      i = i + 1
    end
  end
  return items
end

local function item_hit(it, ch)
  if it.kind == "lit" then return ch == it.ch end
  if it.kind == "any" then return true end
  local cls, hit = it.cls, false
  for n = 1, #cls.items do
    local r = cls.items[n]
    if ch >= r.lo and ch <= r.hi then hit = true break end
  end
  if cls.negate then hit = not hit end
  return hit
end

-- One path segment against one pattern segment. `*` and `?` stop at the separator
-- because the segment they are matching never holds one.
--
-- One backtrack point, moved forward a byte at a time, rather than a recursive branch
-- at every `*`: a name of n bytes against a pattern of m items costs n times m at
-- worst. The recursive form cost two to the power of the stars, so a pattern such as
-- `a*a*a*a*a*a*a*a*b` against a forty-character filename took twelve seconds — inside
-- the matcher, where neither `max_scan` nor `deadline_ms` can see it, so rule 5 (the
-- loop always ends) did not hold for a pattern a model can simply ask for.
local function seg_match(pat, str)
  local items = compile_seg(pat)
  local pi, si = 1, 1
  local star_pi, star_si = nil, nil
  while si <= #str do
    local it = items[pi]
    if it ~= nil and it.kind == "star" then
      star_pi, star_si = pi, si
      pi = pi + 1
    elseif it ~= nil and item_hit(it, string.sub(str, si, si)) then
      pi = pi + 1
      si = si + 1
    elseif star_pi ~= nil then
      star_si = star_si + 1        -- let the last `*` swallow one more byte
      pi = star_pi + 1
      si = star_si
    else
      return false
    end
  end
  while items[pi] ~= nil and items[pi].kind == "star" do pi = pi + 1 end
  return items[pi] == nil
end

-- `**` as a whole segment matches any run of segments, zero included, which is what
-- makes `src/**/*.lua` match `src/a.lua` as well as `src/x/y/a.lua`. `seen` remembers
-- the answer for a (pattern segment, path segment) pair, so a pattern of many `**`
-- costs their number times the path's depth rather than growing with both.
local function seg_list_match(pats, strs, pi, si, seen)
  if pi > #pats then return si > #strs end
  local row = seen[pi]
  if row == nil then row = {} seen[pi] = row end
  local memo = row[si]
  if memo ~= nil then return memo end

  local out
  local p = pats[pi]
  if p == "**" then
    out = false
    for k = si, #strs + 1 do
      if seg_list_match(pats, strs, pi + 1, k, seen) then out = true break end
    end
  elseif si > #strs then
    out = false
  elseif not seg_match(p, strs[si]) then
    out = false
  else
    out = seg_list_match(pats, strs, pi + 1, si + 1, seen)
  end
  row[si] = out
  return out
end

local function tidy_pattern(p)
  p = (string.gsub(p, "^/+", ""))
  while string.sub(p, 1, 2) == "./" do p = string.sub(p, 3) end
  return p
end

-- `true`/`false` for a pattern this matcher accepts; `nil, reason` for one it will not,
-- because matching a brace pattern literally would quietly return the wrong set.
function tools_fs.glob_match(pattern, path)
  if type(pattern) ~= "string" then
    return nil, "a glob pattern is a string, and arrived as " .. type(pattern) .. "."
  end
  if pattern == "" then
    return nil, "an empty glob names nothing; give a pattern such as src/**/*.lua."
  end
  if string.find(pattern, "[{}]") then
    return nil, "brace alternation such as {a,b} is not supported; give one pattern, or widen it with * or **."
  end
  if type(path) ~= "string" then return false end
  return seg_list_match(segments(tidy_pattern(pattern)), segments(tidy_pattern(path)), 1, 1, {})
end

-- Plain, non-overlapping, left to right. An empty needle finds nothing, rather than
-- finding a place between every pair of bytes forever.
function tools_fs.find_all(text, needle)
  local out = {}
  if type(text) ~= "string" or type(needle) ~= "string" or needle == "" then return out end
  local i = 1
  while i <= #text + 1 do
    local s, e = string.find(text, needle, i, true)
    if not s then break end
    out[#out + 1] = s
    i = e + 1
  end
  return out
end

-- 1-based line and column of a byte offset.
function tools_fs.line_of(text, offset)
  if type(text) ~= "string" or not is_whole(offset) then return 1, 1 end
  if offset < 1 then offset = 1 end
  local line, start, i = 1, 1, 1
  while true do
    local j = string.find(text, "\n", i, true)
    if not j or j >= offset then break end
    line = line + 1
    start = j + 1
    i = j + 1
  end
  return line, offset - start + 1
end

-- ------------------------------------------------------------------ results

local function ok_result(t)
  t.ok = true
  return t
end

local function fail(code, reason, extra)
  local r = { ok = false, code = code, reason = reason }
  if extra then
    for k, v in pairs(extra) do
      if k ~= "ok" and k ~= "code" and k ~= "reason" then r[k] = v end
    end
  end
  return r
end

-- What a port failure says. The port's own words are passed through, never parsed and
-- never rewritten; only its code is read, so a caller can branch.
local function port_message(err)
  if type(err) == "string" then return err end
  if type(err) == "table" then
    if type(err.message) == "string" and err.message ~= "" then return err.message end
    if type(err.code) == "string" then return err.code end
  end
  if err == nil then return "no reason given" end
  return tostring(err)
end

local function port_code(err)
  if type(err) == "table" and type(err.code) == "string" then return err.code end
  return nil
end

local function from_port(call, err, rel)
  local code, message = port_code(err), port_message(err)
  if code == "not_found" then
    return fail("not_found", "there is no " .. rel .. " in the workspace.", { path = rel })
  elseif code == "too_big" then
    return fail("too_large", "the workspace refused " .. rel .. " as too big: " .. message, { path = rel })
  elseif code == "denied" then
    return fail("denied", "the workspace refused " .. rel .. ": " .. message, { path = rel })
  end
  return fail("port_failed", call .. " failed: " .. message, { path = rel })
end

-- ------------------------------------------------------------------ the port slice

-- The filesystem the tools use: the one on the context if the harness handed one over,
-- otherwise the one named at install. A port call that raises instead of returning is
-- a broken host, and becomes a result rather than escaping into the turn loop.
local function fs_of(cfg, ctx)
  if type(ctx) == "table" and type(ctx.fs) == "table" then return ctx.fs end
  return cfg.fs
end

local function clock_of(cfg, ctx)
  if type(ctx) == "table" and type(ctx.clock) == "table" then return ctx.clock end
  return cfg.clock
end

local function call_fs(fs, name, a, b)
  if type(fs) ~= "table" or type(fs[name]) ~= "function" then
    return nil, fail("port_failed", "this run has no filesystem port, so fs." .. name .. " cannot be called.")
  end
  local ran, one, two = pcall(fs[name], a, b)
  if not ran then
    return nil, fail("port_failed", "fs." .. name .. " raised: " .. port_message(one))
  end
  if one == nil then
    return nil, from_port("fs." .. name, two, type(a) == "string" and a or "")
  end
  return one
end

local function fs_read(fs, rel)
  if type(fs) ~= "table" or type(fs.read) ~= "function" then
    return nil, fail("port_failed", "this run has no filesystem port, so fs.read cannot be called.")
  end
  local ran, one, two = pcall(fs.read, rel)
  if not ran then
    return nil, fail("port_failed", "fs.read raised: " .. port_message(one))
  end
  if one == nil then
    -- A missing file and a directory read the same way to a flat port, so the one is
    -- told from the other by asking whether it lists.
    if port_code(two) == "not_found" then
      local entries = nil
      if type(fs.list) == "function" then
        local listed, got = pcall(fs.list, rel)
        if listed and got ~= nil then entries = got end
      end
      if entries then
        return nil, fail("not_a_file", rel .. " is a directory; read a file inside it, or list it.", { kind = "dir", path = rel })
      end
    end
    return nil, from_port("fs.read", two, rel)
  end
  if type(one) ~= "string" then
    return nil, fail("port_failed", "fs.read answered with " .. type(one) .. " where the file's bytes belong.")
  end
  return one
end

local function fs_exists(fs, rel)
  if type(fs) ~= "table" or type(fs.exists) ~= "function" then return nil end
  local ran, got = pcall(fs.exists, rel)
  if not ran then return nil end
  return got and true or false
end

-- ------------------------------------------------------------------ deny and gate

local function deny_hit(deny, rel)
  for i = 1, #deny do
    if tools_fs.glob_match(deny[i], rel) == true then return deny[i] end
  end
  return nil
end

-- The one gate every tool passes its path through: resolve, then the deny list.
local function gate(cfg, path, field)
  local abs, rel, reason, extra = tools_fs.resolve(cfg.root, path)
  if abs == nil then
    local code = rel
    if code == "bad_args" then
      return nil, fail("bad_args", reason, { field = field or "path" })
    end
    return nil, fail(code, reason, extra)
  end
  if rel ~= "" then
    local hit = deny_hit(cfg.deny, rel)
    if hit then
      return nil, fail("denied", "this workspace keeps " .. rel .. " out of reach, by the rule " .. hit .. ".", { pattern = hit, path = rel })
    end
  end
  return rel
end

-- ------------------------------------------------------------------ the walk

local function now_ms(clock)
  if type(clock) ~= "table" then return nil end
  local f = clock.mono or clock.now
  if type(f) ~= "function" then return nil end
  local ran, secs = pcall(f)
  if not ran or type(secs) ~= "number" then return nil end
  return secs * 1000
end

local function new_walk(cfg, fs, clock, visit)
  local st = {
    fs = fs, visit = visit, deny = cfg.deny,
    scanned = 0, skipped = 0, max_scan = cfg.max_scan,
    stop = nil, elapsed = 0,
  }
  if cfg.deadline_ms then
    st.deadline = cfg.deadline_ms
    st.started = now_ms(clock)
    if st.started == nil then
      st.no_clock = true
    end
  end
  return st
end

local function past_deadline(st, clock)
  if not st.deadline or st.started == nil then return false end
  local at = now_ms(clock)
  if at == nil then return false end
  st.elapsed = at - st.started
  if st.elapsed > st.deadline then
    st.stop = "deadline"
    return true
  end
  return false
end

local function by_name(a, b)
  return tostring(a.name) < tostring(b.name)
end

local function walk(st, clock, dir, depth)
  if st.stop then return end
  if past_deadline(st, clock) then return end
  if type(st.fs) ~= "table" or type(st.fs.list) ~= "function" then
    st.skipped = st.skipped + 1
    return
  end
  local entries = nil
  local ran, one = pcall(st.fs.list, dir)
  if ran and one ~= nil then entries = one end
  if type(entries) ~= "table" then
    st.skipped = st.skipped + 1
    return
  end

  local sorted = {}
  for i = 1, #entries do
    local e = entries[i]
    if type(e) == "table" and type(e.name) == "string" then sorted[#sorted + 1] = e end
  end
  table.sort(sorted, by_name)

  for i = 1, #sorted do
    if st.stop then return end
    local e = sorted[i]
    local name = e.name
    if name ~= "" and name ~= "." and name ~= ".." and not string.find(name, "/", 1, true) then
      if st.scanned >= st.max_scan then
        st.stop = "budget"
        return
      end
      st.scanned = st.scanned + 1
      if past_deadline(st, clock) then return end

      local p = join(dir, name)
      local kind = type(e.kind) == "string" and e.kind or "file"
      local blocked = deny_hit(st.deny, p)
      if not blocked then
        st.visit(p, kind, type(e.size) == "number" and e.size or nil)
        -- A link is listed and never descended into: lexical resolution cannot see
        -- where it points, so following one is how a walk leaves the workspace.
        if kind == "dir" and depth > 1 then
          walk(st, clock, p, depth - 1)
        end
      end
    end
  end
end

-- Everything a walking tool returns, with the partial answer kept when a budget or a
-- deadline ended it: half an answer beats none.
local function walk_close(st, body)
  if st.stop == "budget" then
    body.ok = false
    body.code = "budget"
    body.reason = "the walk visited its limit of " .. st.max_scan .. " entries before it finished; name a directory further in, or a narrower pattern."
    body.scanned = st.scanned
    return body
  end
  if st.stop == "deadline" then
    body.ok = false
    body.code = "deadline"
    body.reason = "the walk ran past its budget of " .. st.deadline .. "ms; name a directory further in, or a narrower pattern."
    body.elapsed_ms = st.elapsed
    body.scanned = st.scanned
    return body
  end
  body.ok = true
  body.scanned = st.scanned
  return body
end

-- ------------------------------------------------------------------ argument checks

local function want_string(args, field)
  local v = args[field]
  if type(v) ~= "string" then
    return nil, fail("bad_args", "`" .. field .. "` is a string, and arrived as " .. type(v) .. ".", { field = field })
  end
  return v
end

local function want_count(args, field)
  local v = args[field]
  if v == nil then return nil, nil end
  if not positive_whole(v) then
    return nil, fail("bad_args", "`" .. field .. "` is a whole number, at least one, and arrived as " .. tostring(v) .. ".", { field = field })
  end
  return v, nil
end

local function args_of(ctx)
  if type(ctx) == "table" and type(ctx.args) == "table" then return ctx.args end
  return {}
end

-- ------------------------------------------------------------------ read

local function slice_lines(text, offset, limit)
  local starts, total = line_starts(text)
  local from = offset or 1
  if from > total then
    return "", 0, from, from - 1, true
  end
  local to = total
  if limit then
    to = from + limit - 1
    if to > total then to = total end
  end
  local first = starts[from]
  local last
  if to >= total then
    last = #text
  else
    last = starts[to + 1] - 1
  end
  local cut = string.sub(text, first, last)
  local _, n = line_starts(cut)
  return cut, n, from, to, to >= total
end

local function do_read(cfg, ctx)
  local args = args_of(ctx)
  local path, bad = want_string(args, "path")
  if not path then return bad end
  local offset, bad2 = want_count(args, "offset")
  if bad2 then return bad2 end
  local limit, bad3 = want_count(args, "limit")
  if bad3 then return bad3 end

  local rel, refused = gate(cfg, path)
  if not rel then return refused end
  if rel == "" then
    return fail("not_a_file", "that names the workspace root, which is a directory; name a file inside it.", { kind = "dir" })
  end

  local fs = fs_of(cfg, ctx)
  local text, err = fs_read(fs, rel)
  if not text then return err end

  local whole = (offset == nil and limit == nil)
  if whole and #text > cfg.max_bytes then
    return fail("too_large",
      rel .. " is " .. #text .. " bytes, over the limit of " .. cfg.max_bytes .. "; read part of it with offset and limit, or search it instead.",
      { size = #text, limit = cfg.max_bytes, path = rel })
  end
  if looks_binary(text) then
    return fail("binary", rel .. " holds a zero byte, so it is not text and its bytes would be nonsense to read.", { size = #text, path = rel })
  end

  local cut, lines, from_line, to_line, eof = slice_lines(text, offset, limit)
  if #cut > cfg.max_bytes then
    return fail("too_large",
      "those " .. lines .. " lines come to " .. #cut .. " bytes, over the limit of " .. cfg.max_bytes .. "; ask for fewer with limit.",
      { size = #cut, limit = cfg.max_bytes, path = rel })
  end

  return ok_result {
    path = rel, text = cut, bytes = #cut, lines = lines,
    from_line = from_line, to_line = to_line, eof = eof,
  }
end

-- ------------------------------------------------------------------ write

-- What the parent directory says about a name: whether it is there, and how big.
-- `nil` for "no idea": a run with no filesystem port has to reach the write below and
-- be refused there, not raise on the way.
local function look(fs, rel)
  if type(fs) ~= "table" or type(fs.list) ~= "function" then return nil, nil, nil end
  local dir, name = parent_of(rel)
  local ran, entries = pcall(fs.list, dir)
  if ran and type(entries) == "table" then
    for i = 1, #entries do
      local e = entries[i]
      if type(e) == "table" and e.name == name then
        return true, (type(e.kind) == "string" and e.kind or "file"), (type(e.size) == "number" and e.size or nil)
      end
    end
    return false, nil, nil
  end
  local there = fs_exists(fs, rel)
  if there == nil then return nil, nil, nil end
  return there, nil, nil
end

local function do_write(cfg, ctx)
  local args = args_of(ctx)
  if cfg.read_only then
    return fail("read_only", "this workspace is open for reading only, so nothing can be written to it.")
  end
  local path, bad = want_string(args, "path")
  if not path then return bad end
  local text, bad2 = want_string(args, "text")
  if not text then return bad2 end

  local rel, refused = gate(cfg, path)
  if not rel then return refused end
  if rel == "" then
    return fail("not_a_file", "that names the workspace root, which is a directory; name a file inside it.", { kind = "dir" })
  end

  local fs = fs_of(cfg, ctx)
  local there, kind, size = look(fs, rel)
  if there and kind == "dir" then
    return fail("not_a_file", rel .. " is a directory, and a directory cannot be written over.", { kind = "dir", path = rel })
  end

  local wrote, err = call_fs(fs, "write", rel, text)
  if not wrote then return err end

  local created = (there == false)
  return ok_result {
    path = rel, bytes = #text, created = created,
    bytes_before = (created and nil) or size,
  }
end

-- ------------------------------------------------------------------ edit

local function squeeze(s)
  s = (string.gsub(s, "%s+", " "))
  s = (string.gsub(s, "^ ", ""))
  s = (string.gsub(s, " $", ""))
  return s
end

local function lines_of(text)
  local out, i = {}, 1
  while true do
    local j = string.find(text, "\n", i, true)
    if not j then
      if i <= #text then out[#out + 1] = string.sub(text, i) end
      break
    end
    out[#out + 1] = string.sub(text, i, j - 1)
    i = j + 1
  end
  return out
end

-- The near miss: one window of lines that differs from `old` in whitespace alone.
-- It is reported, never applied — repairing the model's copy is how the wrong line
-- gets edited.
local function near_miss(text, old)
  local want = squeeze(old)
  if want == "" then return nil end
  local file = lines_of(text)
  local k = #lines_of(old)
  if k < 1 then k = 1 end
  local found, count = nil, 0
  for i = 1, #file - k + 1 do
    local window = table.concat(file, "\n", i, i + k - 1)
    if squeeze(window) == want then
      count = count + 1
      if count > 1 then return nil end
      found = { line = i, hint = string.sub(file[i], 1, HINT) }
    end
  end
  return found
end

local function do_edit(cfg, ctx)
  local args = args_of(ctx)
  if cfg.read_only then
    return fail("read_only", "this workspace is open for reading only, so nothing in it can be edited.")
  end
  local path, bad = want_string(args, "path")
  if not path then return bad end
  local old, bad2 = want_string(args, "old")
  if not old then return bad2 end
  local new, bad3 = want_string(args, "new")
  if not new then return bad3 end
  local expect, bad4 = want_count(args, "expect")
  if bad4 then return bad4 end

  -- Where the path lands is settled before anything is said about the text: a path
  -- that leaves the workspace, or that a deny rule keeps out of reach, is refused as
  -- that and not as "this edit would change nothing", which would answer a question
  -- about a file this tool has no business having an opinion on.
  local rel, refused = gate(cfg, path)
  if not rel then return refused end
  if rel == "" then
    return fail("not_a_file", "that names the workspace root, which is a directory; name a file inside it.", { kind = "dir" })
  end

  if old == "" then
    return fail("bad_args", "`old` is the exact text to replace and cannot be empty; to put down a whole file, use write.", { field = "old" })
  end
  if old == new then
    return fail("unchanged", "`old` and `new` are the same text, so this edit would change nothing.")
  end

  local fs = fs_of(cfg, ctx)
  local text, err = fs_read(fs, rel)
  if not text then return err end
  if #text > cfg.max_bytes then
    return fail("too_large",
      rel .. " is " .. #text .. " bytes, over the limit of " .. cfg.max_bytes .. ", so it cannot be edited whole.",
      { size = #text, limit = cfg.max_bytes, path = rel })
  end

  local at = tools_fs.find_all(text, old)
  local n = #at

  if n == 0 then
    local extra = { path = rel }
    local near = near_miss(text, old)
    if near then extra.near = near end
    local reason = "that text is not in " .. rel .. "; copy it from a read of the file, byte for byte."
    if string.find(text, "\r\n", 1, true) and not string.find(old, "\r", 1, true) then
      extra.crlf = true
      reason = reason .. " The file ends its lines with a carriage return and a newline, and `old` has only newlines."
    elseif near then
      reason = reason .. " Line " .. near.line .. " is the same but for its spacing."
    end
    return fail("no_match", reason, extra)
  end

  local wanted = expect or 1
  if n ~= wanted then
    local where = {}
    for i = 1, n do
      if i > ITEMS then break end
      local line = tools_fs.line_of(text, at[i])
      where[#where + 1] = line
    end
    local reason
    if expect then
      reason = "that text is in " .. rel .. " " .. n .. " times, not the " .. expect .. " you expected; nothing was changed."
    else
      reason = "that text is in " .. rel .. " " .. n .. " times, so which one to change is a guess; add enough surrounding lines to name one, or set expect to " .. n .. "."
    end
    return fail("ambiguous", reason, { count = n, lines = where, path = rel })
  end

  local parts, from = {}, 1
  for i = 1, n do
    parts[#parts + 1] = string.sub(text, from, at[i] - 1)
    parts[#parts + 1] = new
    from = at[i] + #old
  end
  parts[#parts + 1] = string.sub(text, from)
  local built = table.concat(parts)

  local wrote, werr = call_fs(fs, "write", rel, built)
  if not wrote then return werr end

  local line = tools_fs.line_of(text, at[1])
  return ok_result { path = rel, replaced = n, bytes = #built, line = line }
end

-- ------------------------------------------------------------------ list

-- Is this a directory the walk can start from? A flat port answers `not_found` for a
-- file listed as a directory, so `exists` tells the two apart.
local function start_dir(fs, rel)
  -- The port is checked before the root is waved through: a walk that starts at the
  -- workspace root with no filesystem to walk used to raise on the first list, and a
  -- port that answers nothing used to come back as an empty workspace, which is a
  -- wrong answer rather than a refused one.
  if type(fs) ~= "table" or type(fs.list) ~= "function" then
    return nil, fail("port_failed", "this run has no filesystem port, so fs.list cannot be called.")
  end
  if rel == "" then return true end
  local ran, one, two = pcall(fs.list, rel)
  if not ran then
    return nil, fail("port_failed", "fs.list raised: " .. port_message(one))
  end
  if one ~= nil then return true end
  if port_code(two) == "not_found" then
    if fs_exists(fs, rel) then
      return nil, fail("not_a_dir", rel .. " is a file, not a directory.", { kind = "file", path = rel })
    end
    return nil, fail("not_found", "there is no " .. rel .. " in the workspace.", { path = rel })
  end
  return nil, from_port("fs.list", two, rel)
end

local function cut_to(list, max)
  if #list <= max then return list, false end
  local out = {}
  for i = 1, max do out[i] = list[i] end
  return out, true
end

local function do_list(cfg, ctx)
  local args = args_of(ctx)
  local path = args.path
  if path == nil then path = "" end
  if type(path) ~= "string" then
    return fail("bad_args", "`path` is a workspace-relative directory, and arrived as " .. type(path) .. ".", { field = "path" })
  end
  local depth, bad = want_count(args, "depth")
  if bad then return bad end

  local rel, refused = gate(cfg, path)
  if not rel then return refused end

  local fs = fs_of(cfg, ctx)
  local okdir, err = start_dir(fs, rel)
  if not okdir then return err end

  local note = nil
  local want = depth or 1
  if want > cfg.max_depth then
    want = cfg.max_depth
    note = "depth clamped to " .. cfg.max_depth
  end

  local found = {}
  local st = new_walk(cfg, fs, clock_of(cfg, ctx), function (p, kind, size)
    found[#found + 1] = { path = p, kind = kind, size = (kind == "file" and size) or nil }
  end)
  if cfg.deadline_ms and st.no_clock then
    return fail("port_failed", "a deadline of " .. cfg.deadline_ms .. "ms is set and this run has no clock port to measure it with.")
  end

  walk(st, clock_of(cfg, ctx), rel, want)

  table.sort(found, function (a, b) return a.path < b.path end)
  local entries, truncated = cut_to(found, cfg.max_entries)

  local body = { path = rel, entries = entries, count = #entries, truncated = truncated }
  if note then body.note = note end
  return walk_close(st, body)
end

-- ------------------------------------------------------------------ glob

local function do_glob(cfg, ctx)
  local args = args_of(ctx)
  local pattern, bad = want_string(args, "pattern")
  if not pattern then return bad end
  local path = args.path
  if path == nil then path = "" end
  if type(path) ~= "string" then
    return fail("bad_args", "`path` is a workspace-relative directory, and arrived as " .. type(path) .. ".", { field = "path" })
  end

  local test, why = tools_fs.glob_match(pattern, "")
  if test == nil then
    return fail("unsupported_pattern", why, { pattern = pattern })
  end

  local rel, refused = gate(cfg, path)
  if not rel then return refused end

  local fs = fs_of(cfg, ctx)
  local okdir, err = start_dir(fs, rel)
  if not okdir then return err end

  local found = {}
  local st = new_walk(cfg, fs, clock_of(cfg, ctx), function (p, kind)
    if kind ~= "dir" and tools_fs.glob_match(pattern, p) == true then
      found[#found + 1] = p
    end
  end)
  if cfg.deadline_ms and st.no_clock then
    return fail("port_failed", "a deadline of " .. cfg.deadline_ms .. "ms is set and this run has no clock port to measure it with.")
  end

  walk(st, clock_of(cfg, ctx), rel, cfg.max_depth)

  table.sort(found)
  local paths, truncated = cut_to(found, cfg.max_entries)
  return walk_close(st, { pattern = pattern, paths = paths, count = #paths, truncated = truncated })
end

-- ------------------------------------------------------------------ search

local function trim_eol(line)
  if string.sub(line, -1) == "\r" then return string.sub(line, 1, #line - 1) end
  return line
end

local function do_search(cfg, ctx)
  local args = args_of(ctx)
  local pattern, bad = want_string(args, "pattern")
  if not pattern then return bad end
  if pattern == "" then
    return fail("bad_args", "`pattern` is the text to look for and cannot be empty.", { field = "pattern" })
  end
  local path = args.path
  if path == nil then path = "" end
  if type(path) ~= "string" then
    return fail("bad_args", "`path` is a workspace-relative directory, and arrived as " .. type(path) .. ".", { field = "path" })
  end
  local filter = args.glob
  if filter ~= nil and type(filter) ~= "string" then
    return fail("bad_args", "`glob` is a pattern, and arrived as " .. type(filter) .. ".", { field = "glob" })
  end
  local fixed = args.fixed
  if fixed ~= nil and type(fixed) ~= "boolean" then
    return fail("bad_args", "`fixed` is true or false, and arrived as " .. type(fixed) .. ".", { field = "fixed" })
  end
  local max, bad2 = want_count(args, "max")
  if bad2 then return bad2 end

  if filter then
    local test, why = tools_fs.glob_match(filter, "")
    if test == nil then
      return fail("unsupported_pattern", why, { pattern = filter })
    end
  end

  if not fixed then
    local ran, oops = pcall(string.find, "", pattern)
    if not ran then
      return fail("bad_pattern", "that is not a Lua pattern: " .. port_message(oops) .. ". This tool reads Lua patterns, so %d is a digit and \\d is a backslash followed by a d.", { detail = port_message(oops) })
    end
  end

  local rel, refused = gate(cfg, path)
  if not rel then return refused end

  local fs = fs_of(cfg, ctx)
  local okdir, err = start_dir(fs, rel)
  if not okdir then return err end

  local cap = cfg.max_hits
  if max and max < cap then cap = max end

  local hits, scanned_files, skipped = {}, 0, 0
  local pattern_error = nil
  local st
  st = new_walk(cfg, fs, clock_of(cfg, ctx), function (p, kind)
    if kind == "dir" then return end
    if filter and tools_fs.glob_match(filter, p) ~= true then return end
    local text = fs_read(fs, p)
    if type(text) ~= "string" then
      skipped = skipped + 1
      return
    end
    if #text > cfg.max_bytes or looks_binary(text) then
      skipped = skipped + 1
      return
    end
    scanned_files = scanned_files + 1
    local line_no = 0
    local i = 1
    while i <= #text + 1 do
      local j = string.find(text, "\n", i, true)
      local line = string.sub(text, i, (j and j - 1) or #text)
      line_no = line_no + 1
      if not (line == "" and not j) then
        local ran, s = pcall(string.find, line, pattern, 1, fixed and true or false)
        if not ran then
          -- Some malformed patterns only bite on a line that reaches the bad part.
          pattern_error = port_message(s)
          st.stop = "pattern"
          return
        end
        if s then
          local shown = trim_eol(line)
          local trimmed = false
          if #shown > MAX_LINE then
            shown = string.sub(shown, 1, MAX_LINE)
            trimmed = true
          end
          hits[#hits + 1] = { path = p, line = line_no, col = s, text = shown, trimmed = trimmed }
          if #hits >= cap then
            st.stop = st.stop or "hits"
            return
          end
        end
      end
      if not j then break end
      i = j + 1
    end
  end)
  if cfg.deadline_ms and st.no_clock then
    return fail("port_failed", "a deadline of " .. cfg.deadline_ms .. "ms is set and this run has no clock port to measure it with.")
  end

  walk(st, clock_of(cfg, ctx), rel, cfg.max_depth)

  if pattern_error then
    return fail("bad_pattern", "that is not a Lua pattern: " .. pattern_error .. ". This tool reads Lua patterns, so %d is a digit and \\d is a backslash followed by a d.", { detail = pattern_error })
  end

  local full = (st.stop == "hits")
  if full then st.stop = nil end
  return walk_close(st, {
    pattern = pattern, hits = hits, count = #hits, truncated = full,
    files_scanned = scanned_files, files_skipped = skipped,
  })
end

-- ------------------------------------------------------------------ render

-- A result as the model reads it.
--
-- The bodies above answer with a table, which is what spec/tools_fs.md asks for and
-- what a host that wants the structure needs. A transcript holds text, so something
-- has to turn one into the other, and it cannot be `turn`: rule 1 says the core knows
-- no vendor, and `entries`, `hits` and `from_line` are this subsystem's words. So it
-- is here, beside the tools that use those words, exactly as tools_shell renders its
-- own result. Pure: no port, no clock, no state, same text for the same table.
--
-- A `nil` result renders as one sentence rather than raising, because a body that
-- answered with nothing is a defect the model can still read.
function tools_fs.render(result)
  if result == nil then
    return "the tool answered with nothing at all."
  end
  if type(result) ~= "table" then
    return "the tool answered with a " .. type(result) .. ", and this tool answers with a table."
  end

  local out = {}
  local function line(s) out[#out + 1] = s end

  if result.ok == false then
    local said = type(result.reason) == "string" and result.reason
      or ("the call failed: " .. tostring(result.code))
    line(said)
    -- The evidence a refusal carries, when it carries any. Named, so the model can
    -- act on it rather than guess what the sentence meant.
    if type(result.count) == "number" and result.count > 0 then
      line("occurrences found: " .. result.count)
    end
    if type(result.near) == "string" and result.near ~= "" then
      line("nearest text in the file:")
      line(result.near)
    end
    if type(result.suggest) == "string" and result.suggest ~= "" then
      line("try: " .. result.suggest)
    end
    return table.concat(out, "\n")
  end

  local path = type(result.path) == "string" and result.path or "?"

  if type(result.text) == "string" then                       -- read
    local from = result.from_line or 1
    local to   = result.to_line or result.lines or from
    local head = path .. ", lines " .. from .. "-" .. to
    if type(result.lines) == "number" then head = head .. " of " .. result.lines end
    if result.eof == false then head = head .. ", more follows" end
    line(head)
    line(result.text)

  elseif type(result.entries) == "table" then                 -- list
    line((path == "" and "the workspace root" or path)
      .. ": " .. #result.entries .. (#result.entries == 1 and " entry" or " entries"))
    for i = 1, #result.entries do
      local e = result.entries[i]
      local name = type(e.path) == "string" and e.path or "?"
      if e.kind == "dir" then
        line("  " .. name .. "/")
      elseif type(e.size) == "number" then
        line("  " .. name .. "  " .. e.size .. " bytes")
      else
        line("  " .. name)
      end
    end

  elseif type(result.paths) == "table" then                   -- glob
    line(#result.paths .. (#result.paths == 1 and " file matches " or " files match ")
      .. tostring(result.pattern))
    for i = 1, #result.paths do line("  " .. tostring(result.paths[i])) end

  elseif type(result.hits) == "table" then                    -- search
    line(#result.hits .. (#result.hits == 1 and " line matches " or " lines match ")
      .. tostring(result.pattern))
    for i = 1, #result.hits do
      local h = result.hits[i]
      line("  " .. tostring(h.path) .. ":" .. tostring(h.line) .. ": " .. tostring(h.text)
        .. (h.trimmed and " ..." or ""))
    end

  elseif type(result.replaced) == "number" then               -- edit
    line("edited " .. path .. ": replaced " .. result.replaced
      .. (result.replaced == 1 and " occurrence" or " occurrences")
      .. (type(result.line) == "number" and (" at line " .. result.line) or "")
      .. ", " .. tostring(result.bytes) .. " bytes now")

  elseif result.created ~= nil then                           -- write
    line((result.created and "created " or "replaced ") .. path
      .. ", " .. tostring(result.bytes) .. " bytes"
      .. (type(result.bytes_before) == "number"
          and (" (was " .. result.bytes_before .. ")") or ""))

  else
    -- Something this renderer has not been taught. Say so rather than say nothing:
    -- a stable, sorted dump beats a silent empty result.
    local keys = {}
    for k, v in pairs(result) do
      if k ~= "ok" and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
        keys[#keys + 1] = tostring(k)
      end
    end
    table.sort(keys)
    line("the call succeeded")
    for i = 1, #keys do line("  " .. keys[i] .. " = " .. tostring(result[keys[i]])) end
  end

  if result.truncated == true then
    line("(cut short: ask again for a narrower part)")
  end
  if type(result.note) == "string" and result.note ~= "" then
    line("(" .. result.note .. ")")
  end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------ install

local function bad_opt(what, ...)
  error("tools_fs.install: " .. string.format(what, ...), 3)
end

local function whole_opt(opts, key, default)
  local v = opts[key]
  if v == nil then return default end
  if not positive_whole(v) then
    bad_opt("`%s` is a whole number of at least one, and arrived as %s", key, tostring(v))
  end
  return v
end

local FS_CALLS = { "read", "write", "list", "exists" }
local LOGICAL  = { "read", "write", "edit", "list", "glob", "search" }

-- The declaration surface, called exactly as a hand-written file calls it:
-- `agent.tool "read" { ... }`. The two-argument form is accepted too, so a host that
-- wired its own prefix table is not shut out.
local function declare(agent, name, def)
  local curried, made = pcall(agent.tool, name)
  if curried and type(made) == "function" then
    made(def)
    return
  end
  agent.tool(name, def)
end

function tools_fs.install(agent, opts)
  if type(agent) ~= "table" then
    bad_opt("the first argument is the `agent` prefix table, and arrived as %s", type(agent))
  end
  if type(agent.tool) ~= "function" then
    bad_opt("`agent.tool` is the surface these tools declare through, and it is not a function")
  end
  local kinds = { "string", "string_opt", "number_opt", "boolean_opt" }
  for i = 1, #kinds do
    if type(agent[kinds[i]]) ~= "function" then
      bad_opt("`agent.%s` is missing, and a typed argument cannot be declared without it", kinds[i])
    end
  end

  if opts ~= nil and type(opts) ~= "table" then
    bad_opt("`opts` is a table, and arrived as %s", type(opts))
  end
  opts = opts or {}

  local root = opts.root
  if root == nil then
    root = ""
  elseif type(root) ~= "string" then
    bad_opt("`root` names the workspace root as a string, and arrived as %s", type(root))
  end
  root = (string.gsub(root, "/+$", ""))

  local fs, clock = nil, nil
  if opts.port ~= nil then
    if type(opts.port) ~= "table" then
      bad_opt("`port` is the port table, and arrived as %s", type(opts.port))
    end
    if type(opts.port.fs) ~= "table" then
      bad_opt("`port.fs` is the filesystem port, and arrived as %s", type(opts.port.fs))
    end
    for i = 1, #FS_CALLS do
      if type(opts.port.fs[FS_CALLS[i]]) ~= "function" then
        bad_opt("`port.fs.%s` is not a function, and these tools cannot work without it", FS_CALLS[i])
      end
    end
    fs = opts.port.fs
    if type(opts.port.clock) == "table" then clock = opts.port.clock end
  end

  local deny = {}
  if opts.deny ~= nil then
    if type(opts.deny) ~= "table" then
      bad_opt("`deny` is a list of glob patterns, and arrived as %s", type(opts.deny))
    end
    for i = 1, #opts.deny do
      local p = opts.deny[i]
      if type(p) ~= "string" then
        bad_opt("`deny` entry %d is a glob pattern as a string, and arrived as %s", i, type(p))
      end
      local test, why = tools_fs.glob_match(p, "")
      if test == nil then
        bad_opt("`deny` entry %d, %q, is not a pattern this matcher takes: %s", i, p, why)
      end
      deny[#deny + 1] = p
    end
  end

  if opts.read_only ~= nil and type(opts.read_only) ~= "boolean" then
    bad_opt("`read_only` is true or false, and arrived as %s", type(opts.read_only))
  end

  local deadline_ms = nil
  if opts.deadline_ms ~= nil then
    if not positive_whole(opts.deadline_ms) then
      bad_opt("`deadline_ms` is a whole number of milliseconds, and arrived as %s", tostring(opts.deadline_ms))
    end
    deadline_ms = opts.deadline_ms
    if opts.port ~= nil and type(opts.port.clock) ~= "table" then
      bad_opt("`deadline_ms` needs a clock, and this port has none")
    end
  end

  local ask = { read = false, write = true, edit = true, list = false, glob = false, search = false }
  if opts.ask ~= nil then
    if type(opts.ask) ~= "table" then
      bad_opt("`ask` is a table of tool name to true or false, and arrived as %s", type(opts.ask))
    end
    for i = 1, #LOGICAL do
      local v = opts.ask[LOGICAL[i]]
      if v ~= nil then
        if type(v) ~= "boolean" then
          bad_opt("`ask.%s` is true or false, and arrived as %s", LOGICAL[i], type(v))
        end
        ask[LOGICAL[i]] = v
      end
    end
  end

  local names = {}
  for i = 1, #LOGICAL do names[LOGICAL[i]] = LOGICAL[i] end
  if opts.names ~= nil then
    if type(opts.names) ~= "table" then
      bad_opt("`names` is a table of tool name to tool name, and arrived as %s", type(opts.names))
    end
    for i = 1, #LOGICAL do
      local v = opts.names[LOGICAL[i]]
      if v ~= nil then
        if type(v) ~= "string" or v == "" then
          bad_opt("`names.%s` is a non-empty tool name, and arrived as %s", LOGICAL[i], tostring(v))
        end
        names[LOGICAL[i]] = v
      end
    end
  end

  -- Everything the bodies read, copied so a host that edits `opts` afterwards cannot
  -- change what the tools do. This is the only thing that outlives a call.
  local cfg = {
    root = root, fs = fs, clock = clock, deny = deny,
    read_only = opts.read_only and true or false,
    max_bytes   = whole_opt(opts, "max_bytes",   1048576),
    max_entries = whole_opt(opts, "max_entries", 1000),
    max_scan    = whole_opt(opts, "max_scan",    20000),
    max_depth   = whole_opt(opts, "max_depth",   8),
    max_hits    = whole_opt(opts, "max_hits",    200),
    deadline_ms = deadline_ms,
  }

  local read_note = ""
  if cfg.read_only then
    read_note = " This workspace is open for reading only, so every call to this tool is refused."
  end

  declare(agent, names.read, {
    about = "Read a file from the workspace. Returns its bytes exactly as they are; use offset and limit to read part of a long file.",
    ask = ask.read,
    args = {
      path   = agent.string     "workspace-relative path to the file",
      offset = agent.number_opt "first line to return, counting from one",
      limit  = agent.number_opt "how many lines to return",
    },
    run = function (ctx) return do_read(cfg, ctx) end,
  })

  declare(agent, names.write, {
    about = "Write a whole file, creating it or replacing what is there. To change part of a file, use the edit tool instead." .. read_note,
    ask = ask.write,
    args = {
      path = agent.string "workspace-relative path to the file",
      text = agent.string "the entire new contents of the file",
    },
    run = function (ctx) return do_write(cfg, ctx) end,
  })

  declare(agent, names.edit, {
    about = "Replace an exact piece of text in a file. The old text must appear exactly once, or the edit is refused rather than guessed at." .. read_note,
    ask = ask.edit,
    args = {
      path   = agent.string     "workspace-relative path to the file",
      old    = agent.string     "the exact text to replace, copied from the file",
      new    = agent.string     "the text to put in its place",
      expect = agent.number_opt "replace this many occurrences instead of exactly one",
    },
    run = function (ctx) return do_edit(cfg, ctx) end,
  })

  declare(agent, names.list, {
    about = "List what is in a directory. Directories are marked, and a link is listed but never followed.",
    ask = ask.list,
    args = {
      path  = agent.string_opt "workspace-relative directory, by default the workspace root",
      depth = agent.number_opt "how many levels to descend, by default one",
    },
    run = function (ctx) return do_list(cfg, ctx) end,
  })

  declare(agent, names.glob, {
    about = "Find files whose path matches a pattern, such as src/**/*.lua. Takes * and ** and ? and [a-z]; brace alternation is refused rather than matched as text.",
    ask = ask.glob,
    args = {
      pattern = agent.string     "glob pattern, matched against the whole workspace-relative path",
      path    = agent.string_opt "directory to search under, by default the workspace root",
    },
    run = function (ctx) return do_glob(cfg, ctx) end,
  })

  declare(agent, names.search, {
    about = "Search file contents and return the matching lines. The pattern is a Lua pattern, so %d is a digit and %s is a space; set fixed to true for plain text.",
    ask = ask.search,
    args = {
      pattern = agent.string      "a Lua pattern, or literal text when fixed is true",
      path    = agent.string_opt  "directory to search under, by default the workspace root",
      glob    = agent.string_opt  "only search files whose path matches this glob",
      fixed   = agent.boolean_opt "treat the pattern as literal text, by default false",
      max     = agent.number_opt  "stop after this many hits",
    },
    run = function (ctx) return do_search(cfg, ctx) end,
  })

  local notes = {}
  if fs == nil then
    notes[#notes + 1] = "no filesystem was named at declaration, so these tools use the one the harness hands the tool body"
  end
  notes[#notes + 1] = "a link is listed and never followed; lexical resolution cannot see where one points"
  if cfg.read_only then
    notes[#notes + 1] = "this workspace is open for reading only"
  end

  local tools = {}
  for i = 1, #LOGICAL do tools[LOGICAL[i]] = names[LOGICAL[i]] end
  return { root = root, tools = tools, notes = notes }
end

return tools_fs
