-- store — a program's declared tables of typed rows, which the host holds and the program
-- never does (spec/store.md). `agent.store` declares the shape; the `store` port holds the
-- rows; this file is the view between them that a tool body reaches as `c.store`.
--
--     c.store.rows("habits")                               every row, sorted, as copies
--     c.store.add("habits", { name = "run", done = 0 })
--     c.store.change("habits", { name = "run" }, { done = 1 })   -> how many changed
--     c.store.remove("habits", { name = "run" })                -> how many removed
--
-- The port convention: a wrong shape raises (an unknown store, a column it does not have,
-- a value of the wrong type), and a wrong world returns nil and a reason (the store is
-- full, the host could not write it). Every listing is sorted -- by the store's `sort`
-- columns first, then the rest by name -- so the same rows always print the same bytes.
--
-- The raw port is two functions, so a host can hold rows anywhere:
--
--     read(name)                 -> the rows, or nil when there are none
--     write(name, rows, change)  -> true, or nil and why; change = { op, row, where, set }
--
-- `change` is what happened, for a host that shows it (the console hands it to the UI as
-- an event). This file requires nothing: rule 1 keeps the harness's modules apart.

local store = {}

store.LIMIT = 65536      -- bytes per program, counted the same way everywhere

local function fail(level, fmt, ...) error(string.format(fmt, ...), level + 1) end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- One value against its column's type. Answers the value or nil and why.
local function typed(p, v)
  if v == nil then return nil, "is missing" end
  if p.choices then
    if type(v) ~= "string" then return nil, "must be one of " .. table.concat(p.choices, ", ") end
    for i = 1, #p.choices do if p.choices[i] == v then return v end end
    return nil, "must be one of " .. table.concat(p.choices, ", ") .. ", and is " .. string.format("%q", v)
  end
  if type(v) ~= p.kind then return nil, "must be a " .. p.kind .. ", and is a " .. type(v) end
  return v
end

-- A row checked against the declaration: every column it names is declared, every
-- required column is there, every value has its column's type. Raises on a wrong shape.
local function checked(decl, row, level, partial)
  if type(row) ~= "table" then fail(level, "a row of %q is a table, and arrived as %s", decl.name, type(row)) end
  for k in pairs(row) do
    if decl.columns[k] == nil then
      fail(level, "the store %q has no column %q; it has %s", decl.name, tostring(k),
        table.concat(decl.column_order, ", "))
    end
  end
  local out = {}
  for _, k in ipairs(decl.column_order) do
    local p, v = decl.columns[k], row[k]
    if v == nil then
      if p.required and not partial then fail(level, "a row of %q needs %q", decl.name, k) end
    else
      local good, why = typed(p, v)
      if good == nil then fail(level, "the column %q of %q %s", k, decl.name, why) end
      out[k] = good
    end
  end
  return out
end

-- The order a store's rows are listed in: its `sort` columns, then the rest by name.
local function key_order(decl)
  local order, seen = {}, {}
  for _, k in ipairs(decl.sort or {}) do order[#order + 1] = k; seen[k] = true end
  for _, k in ipairs(decl.column_order) do if not seen[k] then order[#order + 1] = k end end
  return order
end

local RANK = { ["nil"] = 0, boolean = 1, number = 2, string = 3 }

local function less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return RANK[ta] < RANK[tb] end
  if ta == "boolean" then return (not a) and b end
  if ta == "nil" then return false end
  return a < b
end

--- A store's rows in their listing order, as copies.
function store.sorted(decl, rows)
  local out = {}
  for i = 1, #(rows or {}) do out[i] = copy(rows[i]) end
  local order = key_order(decl)
  table.sort(out, function (x, y)
    for _, k in ipairs(order) do
      if x[k] ~= y[k] then return less(x[k], y[k]) end
    end
    return false
  end)
  return out
end

-- How many bytes a store's rows take, counted as their text.
local function size_of(rows)
  local n = 0
  for i = 1, #rows do
    for k, v in pairs(rows[i]) do n = n + #k + #tostring(v) + 2 end
  end
  return n
end

local function matches(row, where)
  for k, v in pairs(where) do if row[k] ~= v then return false end end
  return true
end

--- A row from text, typed by its column: what a data table in a feature holds. Answers
--- the row, or nil and why.
function store.from_text(decl, cells)
  local row = {}
  for k, text in pairs(cells) do
    local p = decl.columns[k]
    if p == nil then
      return nil, "the store " .. string.format("%q", decl.name) .. " has no column " .. string.format("%q", k)
    end
    if text ~= "" then
      if p.kind == "number" then
        row[k] = tonumber(text)
        if row[k] == nil then return nil, "the column " .. string.format("%q", k) .. " is a number, and holds " .. string.format("%q", text) end
      elseif p.kind == "boolean" then
        if text ~= "true" and text ~= "false" then
          return nil, "the column " .. string.format("%q", k) .. " is true or false, and holds " .. string.format("%q", text)
        end
        row[k] = text == "true"
      else
        row[k] = text
      end
    end
  end
  return row
end

--- A row as text, the way a data table shows it.
function store.to_text(decl, row)
  local out = {}
  for _, k in ipairs(key_order(decl)) do
    local v = row[k]
    out[k] = v == nil and "" or tostring(v)
  end
  return out
end

--- The columns in the order a data table lists them.
function store.columns(decl) return key_order(decl) end

--- An in-memory store port: the double in a test, and the console's until its host
--- persists one. `tables` is { name = { row, ... } }.
function store.memory(tables)
  local held = {}
  for name, rows in pairs(tables or {}) do
    held[name] = {}
    for i = 1, #rows do held[name][i] = copy(rows[i]) end
  end
  -- `tables` is the rows themselves, as data, the way the fs double has `files`: a Then
  -- line reads a world whose functions are stubs, so what it reads has to be a table.
  local s = { changes = {}, tables = held }
  function s.read(name)
    local rows = held[name]
    if not rows then return nil end
    local out = {}
    for i = 1, #rows do out[i] = copy(rows[i]) end
    return out
  end
  function s.write(name, rows, change)
    held[name] = {}
    for i = 1, #rows do held[name][i] = copy(rows[i]) end
    s.changes[#s.changes + 1] = { store = name, change = change }
    return true
  end
  function s.names()
    local out = {}
    for name in pairs(held) do out[#out + 1] = name end
    table.sort(out)
    return out
  end
  return s
end

--- The view a tool body reaches as `c.store`, over a raw port and the declaration's
--- stores. Raises on a wrong shape; answers nil and why on a wrong world.
function store.view(raw, decls)
  local v = { __view = true }

  local function decl_of(name, level)
    local d = decls[name]
    if not d then
      local have = {}
      for k in pairs(decls) do have[#have + 1] = k end
      table.sort(have)
      fail(level + 1, "there is no store %q; this program has %s", tostring(name),
        #have > 0 and table.concat(have, ", ") or "none")
    end
    return d
  end

  local function current(d)
    local rows = raw.read(d.name)
    return type(rows) == "table" and rows or {}
  end

  local function put(d, rows, change)
    local sorted = store.sorted(d, rows)
    local total = size_of(sorted)
    for name, other in pairs(decls) do
      if name ~= d.name then total = total + size_of(current(other)) end
    end
    if total > store.LIMIT then
      return nil, "the stores would hold " .. total .. " bytes, past the limit of " .. store.LIMIT
    end
    local ok, why = raw.write(d.name, sorted, change)
    if not ok then return nil, why or "the host could not write the store" end
    return true
  end

  function v.rows(name)
    local d = decl_of(name, 2)
    return store.sorted(d, current(d))
  end

  function v.add(name, row)
    local d = decl_of(name, 2)
    local good = checked(d, row, 2)
    local rows = current(d)
    rows[#rows + 1] = good
    local ok, why = put(d, rows, { op = "add", row = copy(good) })
    if not ok then return nil, why end
    return true
  end

  function v.change(name, where, set)
    local d = decl_of(name, 2)
    if type(where) ~= "table" then fail(2, "store.change takes the store, which rows (a table), and what to set") end
    checked(d, where, 2, true)
    local fields = checked(d, set, 2, true)
    local rows, n = current(d), 0
    for i = 1, #rows do
      if matches(rows[i], where) then
        for k, val in pairs(fields) do rows[i][k] = val end
        n = n + 1
      end
    end
    if n == 0 then return 0 end
    local ok, why = put(d, rows, { op = "change", where = copy(where), set = copy(fields) })
    if not ok then return nil, why end
    return n
  end

  function v.remove(name, where)
    local d = decl_of(name, 2)
    if type(where) ~= "table" then fail(2, "store.remove takes the store and which rows, as a table ({} is every row)") end
    checked(d, where, 2, true)
    local rows, kept, n = current(d), {}, 0
    for i = 1, #rows do
      if matches(rows[i], where) then n = n + 1 else kept[#kept + 1] = rows[i] end
    end
    if n == 0 then return 0 end
    local ok, why = put(d, kept, { op = "remove", where = copy(where) })
    if not ok then return nil, why end
    return n
  end

  return v
end

--- The port a run is handed, with the store as its view: a copy of `port` whose `store`
--- is `store.view` over the raw one. A world with no store gets an empty one in memory,
--- set on the world itself so a Then line can read what the run wrote. A declaration with
--- no store gets the port as it came.
function store.bind(decl, port)
  if type(decl) ~= "table" or type(decl.stores) ~= "table" or next(decl.stores) == nil then return port end
  if type(port) ~= "table" then return port end
  if port.store == nil then port.store = store.memory() end
  if type(port.store) == "table" and port.store.__view then return port end
  local out = {}
  for k, v in pairs(port) do out[k] = v end
  out.store = store.view(port.store, decl.stores)
  return out
end

return store
