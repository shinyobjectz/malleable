-- hdc -- hypervectors (spec/history.md, "Hypervectors").

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local hdc = require "hdc"

local T = {}

local function near(x, want, by) return math.abs(x - want) <= by end

function T.two_names_agree_on_about_half_their_bits()
  local names = { "a", "b", "file1", "file2", "notes/budget.md", "notes/budget.mb", "main", "mainline" }
  for i = 1, #names do
    for j = i + 1, #names do
      local s = hdc.similarity(hdc.atom(names[i]), hdc.atom(names[j]))
      assert(near(s, 0.5, 0.03), names[i] .. " and " .. names[j] .. " agree on " .. s)
    end
  end
  assert(hdc.similarity(hdc.atom "a", hdc.atom "a") == 1)
end

function T.a_names_vector_is_the_same_everywhere()
  -- pinned: the first sixteen hex digits of two names, the same on LuaJIT and Lua 5.5
  local a, m = hdc.hex(hdc.atom "notebook"):sub(1, 16), hdc.hex(hdc.atom "main"):sub(1, 16)
  assert(#hdc.hex(hdc.atom "notebook") == 2048)
  assert(a == "e86ec913f2ee0e63" and m == "bb307b72fa313cfc", "notebook " .. a .. ", main " .. m)
end

function T.binding_twice_undoes_it_and_a_binding_is_near_neither_part()
  local r, f = hdc.atom "role:agent", hdc.atom "notebook"
  local b = hdc.bind(r, f)
  assert(near(hdc.similarity(b, r), 0.5, 0.03) and near(hdc.similarity(b, f), 0.5, 0.03))
  assert(hdc.similarity(hdc.bind(b, r), f) == 1)
end

function T.a_bundle_is_near_each_member_and_not_a_stranger()
  local parts = {}
  for i = 1, 20 do parts[i] = hdc.bind(hdc.atom("role" .. i), hdc.atom("value" .. i)) end
  local v = hdc.bundle(parts)
  for i = 1, 20 do
    assert(hdc.similarity(v, parts[i]) > 0.55, "member " .. i .. " at " .. hdc.similarity(v, parts[i]))
  end
  local stranger = hdc.bind(hdc.atom "role1", hdc.atom "value2")
  assert(near(hdc.similarity(v, stranger), 0.5, 0.03))
  -- and a bundle of two is decided by the tie vector, not left undefined
  local two = hdc.bundle { hdc.atom "x", hdc.atom "y" }
  assert(hdc.similarity(two, hdc.atom "x") > 0.7 and hdc.similarity(two, hdc.atom "y") > 0.7)
end

function T.hours_two_apart_are_nearer_than_ten_and_midnight_wraps()
  local h = function (i) return hdc.level("hour", i, 24) end
  local s1, s2, s10 = hdc.similarity(h(14), h(15)), hdc.similarity(h(14), h(16)), hdc.similarity(h(14), h(0))
  assert(s1 > s2 and s2 > s10, s1 .. " " .. s2 .. " " .. s10)
  assert(near(s10, 0.5, 0.03), "ten hours apart is unrelated: " .. s10)
  assert(hdc.similarity(h(23), h(0)) > 0.85, "23:00 and 00:00 " .. hdc.similarity(h(23), h(0)))
  assert(hdc.similarity(h(24), h(0)) == 1)
  local d = function (i) return hdc.level("day", i, 64) end
  assert(hdc.similarity(d(100), d(101)) > hdc.similarity(d(100), d(110)))
  assert(near(hdc.similarity(d(100), d(130)), 0.5, 0.03))
end

function T.hex_goes_there_and_back()
  local v = hdc.bundle { hdc.atom "p", hdc.atom "q", hdc.atom "r" }
  local back = assert(hdc.from_hex(hdc.hex(v)))
  assert(hdc.similarity(v, back) == 1)
  assert(not hdc.from_hex "ff")
end

function T.the_file_reaches_nothing()
  local f = assert(io.open(here .. "/../src/hdc.lua", "rb"))
  local code = f:read("*a"):gsub("%-%-[^\n]*", "")
  f:close()
  for _, word in ipairs { "io", "os", "require" } do
    assert(not code:find("%f[%w_]" .. word .. "%f[^%w_]"), "hdc.lua names " .. word)
  end
  assert(not code:find("math.random", 1, true))
end

return T
