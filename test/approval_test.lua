-- The approval gate, judged on its failure modes. The adversarial cases come first
-- in spirit: a gate that allows a happy path is not the thing worth proving.

local approval = (function ()
  local ok, m = pcall(require, "approval")
  if ok then return m end
  ok, m = pcall(require, "src.approval")
  if ok then return m end
  local here = debug.getinfo(1, "S").source:sub(2)
  local dir = here:match("^(.*)[/\\][^/\\]*$") or "."
  return dofile(dir .. "/../src/approval.lua")
end)()

local T = {}

-- ------------------------------------------------------------------ doubles

-- A port that records every request and answers from a script. Nothing here decides
-- anything on its own: an unscripted ask answers with whatever `answer` holds.
local function spy(answer)
  local p = { asks = {} }
  p.ask = function (request)
    p.asks[#p.asks + 1] = request
    if type(answer) == "function" then return answer(request, #p.asks) end
    return answer
  end
  return p
end

local function raising_port(message)
  return { ask = function () error(message, 0) end }
end

local function has(s, needle)
  return type(s) == "string" and s:find(needle, 1, true) ~= nil
end

local function shaped(d)
  assert(type(d) == "table", "a decision is a table")
  assert(type(d.allowed) == "boolean", "allowed is never nil")
  assert(type(d.source) == "string" and d.source ~= "", "a decision names its source")
  assert(type(d.reason) == "string" and d.reason ~= "", "a decision carries one sentence")
  assert(#d.reason <= 400, "a reason is bounded")
  assert(type(d.asked) == "boolean", "a decision says whether the port was consulted")
  assert(type(d.remembered) == "boolean", "a decision says whether it was stored")
  if not d.remembered then assert(d.scope == nil, "scope belongs to a remembered answer") end
  return d
end

-- ------------------------------------------------------------------ 1-3, the shape

function T.a_tool_that_does_not_ask_just_runs()
  local port = spy("yes")
  local gate = approval.new { port = port }
  local d = shaped(gate:check { tool = "read", args = { path = "a.txt" }, ask = false })
  assert(d.allowed, "a tool that does not ask runs")
  assert(d.source == "flag", "and says so: " .. d.source)
  assert(d.asked == false, "without asking")
  assert(#port.asks == 0, "the port was never touched")
  assert(has(d.reason, "read"), "the reason names the tool: " .. d.reason)
end

function T.a_tool_that_asks_reaches_the_port()
  local port = spy("yes")
  local gate = approval.new { port = port, trust = "ask" }
  local d = shaped(gate:check { tool = "write", args = { path = "notes.md" }, ask = true })
  assert(d.allowed and d.source == "port" and d.asked, "an asking tool is put to the operator")
  assert(#port.asks == 1, "exactly once")
  local q = port.asks[1]
  assert(q.tool == "write", "the request carries the tool name")
  assert(q.args.path == "notes.md", "and the arguments")
  assert(q.trust == "ask", "and the trust level")
  assert(q.can_remember == true, "and whether these arguments can be keyed")
end

function T.a_refused_call_is_a_result_the_model_reads()
  local gate = approval.new { port = spy("no") }
  local ok, d = pcall(gate.check, gate, { tool = "write", args = {}, ask = true })
  assert(ok, "check returns rather than raising")
  shaped(d)
  assert(d.allowed == false, "a refusal is a refusal")
  assert(d.reason ~= "", "with something the model can read")
  assert(d.source == "port", "from the operator")
end

function T.an_empty_gate_allows_nothing_it_was_not_asked_about()
  local gate = approval.new()
  local d = shaped(gate:check { tool = "shell", ask = true })
  assert(d.allowed == false, "no port is not an open gate")
  assert(d.source == "port" and d.asked == false, "and nobody was asked")
  assert(has(d.reason, "no one to ask"), d.reason)
end

-- ------------------------------------------------------------------ 5-12, policy

function T.a_deny_policy_stops_a_tool_that_never_asked()
  local gate = approval.new { policy = { { deny = true, tool = "shell" } } }
  local d = shaped(gate:check { tool = "shell", args = { cmd = "ls" }, ask = false })
  assert(d.allowed == false and d.source == "policy", "policies are read for every call")
  assert(d.policy == 1, "and name the entry")
end

function T.deny_beats_allow_in_either_order()
  local allow_first = approval.new {
    policy = { { allow = true, tool = "write" }, { deny = true, tool = "write" } },
  }
  local deny_first = approval.new {
    policy = { { deny = true, tool = "write" }, { allow = true, tool = "write" } },
  }
  local a = shaped(allow_first:check { tool = "write", ask = false })
  local b = shaped(deny_first:check { tool = "write", ask = false })
  assert(a.allowed == false and b.allowed == false, "the deny wins whichever way round")
  assert(a.policy == 2 and b.policy == 1, "and each names its own entry")
  assert(a.source == "policy" and b.source == "policy", "from the policy")
end

function T.deny_beats_trust()
  local gate = approval.new {
    trust = "trusted",
    policy = { { deny = true, tool = "shell", reason = "not on this workspace" } },
  }
  local d = shaped(gate:check { tool = "shell", ask = false })
  assert(d.allowed == false, "a trusted workspace still cannot touch a denied tool")
  assert(has(d.reason, "not on this workspace"), d.reason)
end

function T.deny_beats_an_always_the_operator_already_gave()
  local gate = approval.new { policy = { { deny = true, tool = "write" } } }
  assert(gate:remember("write", true), "the operator said always")
  local d = shaped(gate:check { tool = "write", ask = true })
  assert(d.allowed == false and d.source == "policy", "and still cannot pass a deny")
end

function T.an_untrusted_workspace_asks_about_everything()
  local port = spy("yes")
  local gate = approval.new { port = port, trust = "none" }
  local d = shaped(gate:check { tool = "read", args = { path = "a" }, ask = false })
  assert(d.asked and d.allowed, "even a tool that never declared ask is put to the human")
  assert(port.asks[1].trust == "none", "and the request says why")
end

function T.an_argument_pattern_narrows_a_policy()
  local port = spy("no")
  local gate = approval.new {
    port = port,
    policy = { { allow = true, tool = "write", when = { path = "^notes/" } } },
  }
  local inside = shaped(gate:check { tool = "write", args = { path = "notes/a.md" }, ask = true })
  assert(inside.allowed and inside.source == "policy", "a call under notes/ is allowed by policy")
  assert(#port.asks == 0, "without asking")
  local outside = shaped(gate:check { tool = "write", args = { path = "src/a.lua" }, ask = true })
  assert(outside.allowed == false and outside.source == "port", "one outside falls to the port")
  assert(#port.asks == 1, "which was consulted once")
end

function T.a_missing_argument_never_matches()
  local port = spy("no")
  local denier = approval.new {
    port = port,
    policy = { { deny = true, tool = "write", when = { path = "^/" } } },
  }
  local d = shaped(denier:check { tool = "write", args = { text = "x" }, ask = false })
  assert(d.allowed, "a deny with a when does not fire on a call with no such argument")
  assert(d.source == "flag", d.source)

  local allower = approval.new {
    port = port,
    policy = { { allow = true, tool = "write", when = { path = "^notes/" } } },
  }
  local e = shaped(allower:check { tool = "write", args = {}, ask = true })
  assert(e.allowed == false and e.source == "port", "and neither does an allow")

  -- a function matcher is not even called: absence is decided before the matcher
  local called = false
  local fn = approval.new {
    port = port,
    policy = { { deny = true, tool = "write", when = { path = function ()
      called = true
      return true
    end } } },
  }
  local f = shaped(fn:check { tool = "write", args = { text = "x" }, ask = false })
  assert(f.allowed and f.source == "flag", "a function matcher does not see a missing argument")
  assert(called == false, "and is never called for one")
end

function T.a_table_argument_never_matches_a_string_matcher()
  local gate = approval.new {
    policy = { { deny = true, tool = "write", when = { path = "table" } } },
  }
  local one = shaped(gate:check { tool = "write", args = { path = {} }, ask = false })
  local two = shaped(gate:check { tool = "write", args = { path = { 1, 2, 3 } }, ask = false })
  assert(one.allowed and two.allowed, "a pattern must not match what tostring would print")
  assert(one.source == two.source and one.reason == two.reason, "two tables decide the same way")
end

-- ------------------------------------------------------------------ 13-16, memory

function T.always_is_remembered_for_the_run_and_only_the_run()
  local policy = { { deny = true, tool = "shell" } }
  local port = spy("always")
  local gate = approval.new { port = port, policy = policy }
  local first = shaped(gate:check { tool = "write", args = { path = "a" }, ask = true })
  assert(first.allowed and first.remembered and first.scope == "tool", "always is kept")
  local second = shaped(gate:check { tool = "write", args = { path = "b" }, ask = true })
  assert(second.allowed and second.source == "memory" and second.asked == false, "and is not asked twice")
  assert(#port.asks == 1, "the port saw one request")

  local fresh = approval.new { port = spy("always"), policy = policy }
  local again = shaped(fresh:check { tool = "write", args = { path = "a" }, ask = true })
  assert(again.source == "port" and again.asked, "a fresh gate remembers nothing")
end

function T.never_is_remembered_the_same_way()
  local port = spy("never")
  local gate = approval.new { port = port }
  local first = shaped(gate:check { tool = "write", ask = true })
  assert(first.allowed == false and first.remembered, "never is kept")
  local second = shaped(gate:check { tool = "write", args = { path = "x" }, ask = true })
  assert(second.allowed == false and second.source == "memory" and not second.asked, "and holds")
  assert(has(second.reason, "rest of this run"), second.reason)
  assert(#port.asks == 1, "the operator was asked once")
end

function T.always_with_a_table_argument_applies_once()
  local port = spy { answer = "always", scope = "args" }
  local gate = approval.new { port = port }
  local call = { tool = "write", args = { path = "a", body = { 1, 2 } }, ask = true }
  local d = shaped(gate:check(call))
  assert(d.allowed, "the call is allowed")
  assert(d.remembered == false, "and not remembered, because these arguments cannot be keyed")
  assert(has(d.reason, "this call only"), d.reason)
  assert(port.asks[1].can_remember == false, "the request said so in advance")
  shaped(gate:check(call))
  assert(#port.asks == 2, "so the next identical call is asked again")
end

function T.cyclic_arguments_do_not_hang_the_gate()
  local args = { path = "a" }
  args.self = args
  local port = spy { answer = "always", scope = "args" }
  local gate = approval.new { port = port }
  local d = shaped(gate:check { tool = "write", args = args, ask = true })
  assert(d.allowed and d.remembered == false, "a cycle is never walked into")
  assert(#gate:remembered() == 0, "and nothing was stored")
end

-- ------------------------------------------------------------------ 17-22, the port

function T.a_port_that_raises_denies()
  local gate = approval.new { port = raising_port("the terminal is gone") }
  local ok, d = pcall(gate.check, gate, { tool = "write", ask = true })
  assert(ok, "no error escapes check")
  shaped(d)
  assert(d.allowed == false and d.source == "port", "a raising port is a refusal")
  assert(has(d.reason, "the terminal is gone"), d.reason)
end

function T.a_port_that_answers_nonsense_denies()
  local cases = { 42, "allow", {}, { answer = "maybe" }, { scope = "args" } }
  for i = 1, #cases do
    local gate = approval.new { port = spy(cases[i]) }
    local d = shaped(gate:check { tool = "write", ask = true })
    assert(d.allowed == false, "nonsense is a refusal, case " .. i)
    assert(d.source == "port" and d.asked, "from the port, case " .. i)
    assert(has(d.reason, "not yes, no, always or never"), d.reason)
  end
  local number = approval.new { port = spy(42) }
  assert(has(number:check{ tool = "w", ask = true }.reason, "42"), "the offending value is named")
  local word = approval.new { port = spy("allow") }
  assert(has(word:check{ tool = "w", ask = true }.reason, "allow"), "including a misspelt word")
end

function T.a_port_that_answers_nothing_reads_as_no()
  local gate = approval.new { port = spy(nil) }
  local d = shaped(gate:check { tool = "write", ask = true })
  assert(d.allowed == false and d.asked, "nothing is a plain refusal")
  assert(d.reason == "refused by the operator", d.reason)
  assert(not has(d.reason, "not yes, no"), "and is not called nonsense")
end

function T.a_port_answer_survives_whitespace_and_case()
  for _, answer in ipairs { "  YES\n", "Yes", "\tyes ", true } do
    local gate = approval.new { port = spy(answer) }
    local d = shaped(gate:check { tool = "write", ask = true })
    assert(d.allowed, "an operator's newline is not the operator's mistake")
  end
  local gate = approval.new { port = spy(" ALWAYS ") }
  local d = shaped(gate:check { tool = "write", ask = true })
  assert(d.allowed and d.remembered, "and neither is their shift key")
end

function T.an_approval_cannot_ask_for_approval()
  local inner
  local gate
  local port = spy(function ()
    inner = gate:check { tool = "read", ask = true }
    return "yes"
  end)
  gate = approval.new { port = port }
  local outer = shaped(gate:check { tool = "write", ask = true })
  shaped(inner)
  assert(inner.allowed == false and inner.source == "reentry", "the inner call is refused")
  assert(inner.asked == false, "without reaching the port again")
  assert(outer.allowed and outer.source == "port", "the outer call completes")
  local later = shaped(gate:check { tool = "list", ask = true })
  assert(later.source == "port" and later.asked, "and the flag was cleared")
end

function T.a_raising_port_clears_the_in_flight_flag()
  local gate = approval.new { port = raising_port("boom") }
  shaped(gate:check { tool = "write", ask = true })
  local working = spy("yes")
  local next_gate = approval.new { port = working }
  assert(next_gate:check{ tool = "write", ask = true }.allowed, "a fresh gate is unaffected")
  -- the same gate, its port now answering, must reach it again
  local recovering = approval.new { port = spy(function (_, n)
    if n == 1 then error("boom", 0) end
    return "yes"
  end) }
  local first = shaped(recovering:check { tool = "write", ask = true })
  local second = shaped(recovering:check { tool = "write", ask = true })
  assert(first.allowed == false, "the first ask failed")
  assert(second.allowed and second.asked, "the second reached the port")
end

-- ------------------------------------------------------------------ 23-25, hostility

function T.a_matcher_that_raises_denies()
  local gate = approval.new {
    port = spy("yes"),
    policy = {
      { allow = true, tool = "read" },
      { allow = true, tool = "write", when = { path = function () error("bad matcher", 0) end } },
    },
  }
  local d = shaped(gate:check { tool = "write", args = { path = "a" }, ask = false })
  assert(d.allowed == false, "a broken permission check is a stopped agent")
  assert(d.source == "policy" and d.policy == 2, "and names the entry")
  assert(has(d.reason, "2") and has(d.reason, "bad matcher"), d.reason)
end

function T.a_malformed_call_is_a_denial_not_an_error()
  local gate = approval.new { port = spy("yes") }
  local calls = { nil, "read", {}, { tool = "" }, { tool = "read", args = 7 } }
  local cases = { { n = 0 }, { "read" }, { {} }, { { tool = "" } }, { { tool = "read", args = 7 } } }
  for i = 1, #cases do
    local ok, d = pcall(gate.check, gate, cases[i][1])
    assert(ok, "a malformed call does not raise, case " .. i)
    shaped(d)
    assert(d.allowed == false, "a malformed call is a denial, case " .. i)
    assert(d.source == "malformed", "and is flagged as one, case " .. i .. ": " .. d.source)
  end
  assert(calls ~= nil)
end

function T.a_hostile_tool_name_does_not_flood_the_reason()
  local huge = string.rep("x", 100000)
  local plain = approval.new()
  local d = shaped(plain:check { tool = huge, ask = false })
  assert(#d.reason <= 400, "a hostile name is bounded: " .. #d.reason)

  local gate = approval.new { port = spy { answer = "no", reason = string.rep("y", 100000) } }
  local e = shaped(gate:check { tool = huge, ask = true, reason = string.rep("z", 100000) })
  assert(#e.reason <= 400, "and so is a hostile port reason: " .. #e.reason)
end

-- ------------------------------------------------------------------ 26-29, wiring

function T.a_malformed_policy_is_caught_at_construction()
  local cases = {
    { policy = { { allow = true, deny = true, tool = "read" } } },
    { policy = { { tool = "read" } } },
    { policy = { { allow = true }, { deny = true, tools = "read" } } },
    { policy = { { allow = true, tool = "read", when = { path = 7 } } } },
    { policy = { { allow = true }, nil, { deny = true } } },
    { policy = { { allow = true, tool = {} } } },
    { policy = { { allow = true, tool = "read", reason = string.rep("r", 201) } } },
    { policy = { { allow = true, tool = "read", when = { path = "%" } } } },
    { policy = { { allow = true, tool = "read", when = { [1] = "^a" } } } },
    { policy = { { allow = true, tool = { "read", "" } } } },
    { policy = { 7 } },
    { policy = { { allow = false, tool = "read" } } },
    { policy = "read" },
    { trust = "maybe" },
    { port = { ask = "yes" } },
  }
  for i = 1, #cases do
    local ok, err = pcall(approval.new, cases[i])
    assert(not ok, "case " .. i .. " must be refused at construction")
    assert(type(err) == "string" and err ~= "", "with a sentence, case " .. i)
  end

  -- the index is named, so a long declaration file can be repaired
  local _, both = pcall(approval.new, { policy = { { allow = true }, { allow = true, deny = true } } })
  assert(has(both, "2"), both)
  local _, typo = pcall(approval.new, { policy = { { allow = true, tools = "read" } } })
  assert(has(typo, "1") and has(typo, "tools"), typo)
  local _, hole = pcall(approval.new, { policy = { [1] = { allow = true }, [3] = { deny = true } } })
  assert(has(hole, "policy"), hole)
  local _, matcher = pcall(approval.new, { policy = { { allow = true, when = { path = 7 } } } })
  assert(has(matcher, "1") and has(matcher, "path"), matcher)
  local _, pattern = pcall(approval.new, { policy = { { allow = true, when = { path = "%" } } } })
  assert(has(pattern, "1") and has(pattern, "malformed"), pattern)

  assert(pcall(approval.new), "no arguments at all is legal")
  assert(pcall(approval.new, nil), "and so is nil")
end

function T.a_port_wired_wrong_is_caught_at_construction()
  assert(not pcall(approval.new, { port = { ask = "yes" } }), "a port with no ask function is a wiring bug")
  assert(not pcall(approval.new, { port = 7 }), "and so is a port that is not a table")
  assert(pcall(approval.new, { port = { ask = function () return "no" end } }), "the plain shape is fine")
  assert(pcall(approval.new, { port = { request = function () return { allow = false } end } }),
    "and so is the port document's own slice")
end

function T.the_gate_holds_no_shared_state()
  local policy = { { allow = true, tool = "read" } }
  local a = approval.new { port = spy("always"), policy = policy }
  local b = approval.new { port = spy("no"), policy = policy }
  assert(a:check{ tool = "write", ask = true }.allowed, "one gate is told always")
  local d = shaped(b:check { tool = "write", ask = true })
  assert(d.allowed == false and d.source == "port", "the other knows nothing of it")
  assert(#policy == 1 and policy[1].allow == true and policy[1].tool == "read",
    "and neither wrote to the table it was given")
  assert(policy[1].index == nil, "not even a bookkeeping field")
end

function T.forget_undoes_a_remembered_answer()
  local port = spy("always")
  local gate = approval.new { port = port }
  shaped(gate:check { tool = "write", ask = true })
  assert(#gate:remembered() == 1, "one answer is held")
  assert(gate:forget("write") == 1, "and one is dropped")
  shaped(gate:check { tool = "write", ask = true })
  assert(#port.asks == 2, "so the port is reached again")

  assert(gate:remember("read", true), "remember by hand")
  assert(gate:remember("list", false), "and again")
  local held = gate:remembered()
  assert(#held == 3, "three are held, in the order they were made: " .. #held)
  assert(held[2].tool == "read" and held[2].allowed == true, "with their answers")
  assert(held[3].tool == "list" and held[3].allowed == false and held[3].scope == "tool", "and scopes")
  held[1].tool = "clobbered"
  held[#held + 1] = { tool = "invented" }
  assert(#gate:remembered() == 3, "mutating the copy changes nothing")
  assert(gate:remembered()[1].tool ~= "clobbered", "nor does writing into it")
  assert(gate:forget() == 3, "and forget drops the rest")
  assert(#gate:remembered() == 0, "leaving nothing")
end

function T.remember_refuses_bad_arguments_without_raising()
  local gate = approval.new()
  local bad = {
    { "", true }, { nil, true }, { 7, true }, { "read", "yes" },
    { "read", true, "session" }, { "read", true, "args" },
    { "read", true, "args", { body = {} } },
  }
  for i = 1, #bad do
    local ok, stored, why = pcall(gate.remember, gate, bad[i][1], bad[i][2], bad[i][3], bad[i][4])
    assert(ok, "remember never raises, case " .. i)
    assert(stored == false, "and refuses, case " .. i)
    assert(type(why) == "string" and why ~= "", "with a sentence, case " .. i)
  end
  assert(gate:remember("read", true, "args", { path = "a" }), "a keyable args scope is stored")
  local d = shaped(gate:check { tool = "read", args = { path = "a" }, ask = true })
  assert(d.allowed and d.source == "memory", "and answers that exact call")
  local other = shaped(gate:check { tool = "read", args = { path = "b" }, ask = true })
  assert(other.allowed == false and other.source == "port", "but no other")
end

function T.the_gate_never_runs_a_body()
  local ran = false
  local body = { run = function () ran = true end, about = "a tool shape" }
  local gate = approval.new {
    port = spy("yes"),
    policy = { { deny = true, tool = "shell" } },
  }
  local calls = {
    { tool = "read", args = { it = body }, ask = false, run = body.run },
    { tool = "shell", args = { it = body }, ask = true, run = body.run },
    { tool = "write", args = { it = body }, ask = true, run = body.run },
  }
  for i = 1, #calls do
    shaped(gate:check(calls[i]))
    assert(ran == false, "the gate weighs a call and never performs it, case " .. i)
  end
end

-- ------------------------------------------------------------------ 31, the rule

function T.no_vendor_and_no_world_in_the_source()
  local here = debug.getinfo(1, "S").source:sub(2)
  local dir = here:match("^(.*)[/\\][^/\\]*$") or "."
  local paths = { dir .. "/../src/approval.lua", "src/approval.lua", "vendor/malleable/src/approval.lua" }
  local text
  for i = 1, #paths do
    local f = io.open(paths[i], "r")
    if f then text = f:read("*a"); f:close(); break end
  end
  assert(text and #text > 0, "the source must be readable to be judged")
  local banned = {
    "io%.", "os%.", "require", "loadfile", "dofile", "load%s*%(",
    "http", "openai", "anthropic", "openrouter", "curl", "socket",
  }
  for i = 1, #banned do
    assert(not text:find(banned[i]), "the gate names no world and no vendor: " .. banned[i])
  end
end

-- ------------------------------------------------------------------ extras

function T.the_ask_flag_is_the_only_thing_trust_ask_reads()
  local port = spy("yes")
  local gate = approval.new { port = port, trust = "ask" }
  assert(gate:check{ tool = "read", ask = nil }.source == "flag", "a nil ask reads as false")
  assert(gate:check{ tool = "read", ask = false }.source == "flag", "and false is false")
  assert(gate:check{ tool = "read", ask = true }.source == "port", "and true reaches the port")
  assert(#port.asks == 1, "once")
end

function T.a_trusted_workspace_still_reads_its_policies()
  local gate = approval.new {
    trust = "trusted",
    policy = { { allow = true, tool = "read" } },
    port = spy("no"),
  }
  local by_policy = shaped(gate:check { tool = "read", ask = true })
  assert(by_policy.source == "policy", "an allow policy is read before trust")
  local by_trust = shaped(gate:check { tool = "shell", ask = true })
  assert(by_trust.allowed and by_trust.source == "trust", "and trust catches the rest")
  assert(by_trust.reason == "the workspace is trusted", by_trust.reason)
end

function T.an_always_under_no_trust_is_honoured()
  local port = spy("always")
  local gate = approval.new { port = port, trust = "none" }
  assert(gate:check{ tool = "read", ask = false }.allowed, "the operator said always")
  local second = shaped(gate:check { tool = "read", ask = false })
  assert(second.source == "memory" and not second.asked, "and is not asked again")
  assert(#port.asks == 1, "one deliberate decision beats a habit of hammering yes")
end

function T.the_port_document_decision_shape_is_read()
  local allow = approval.new { port = { request = function () return { allow = true, why = "fine" } end } }
  local d = shaped(allow:check { tool = "write", ask = true })
  assert(d.allowed and has(d.reason, "fine"), d.reason)

  local refuse = approval.new { port = { request = function () return { allow = false, why = "no answer" } end } }
  local e = shaped(refuse:check { tool = "write", ask = true })
  assert(e.allowed == false and has(e.reason, "no answer"), e.reason)

  local session = approval.new { port = spy { allow = true, remember = "session" } }
  local f = shaped(session:check { tool = "write", ask = true })
  assert(f.allowed and f.remembered and f.scope == "tool", "a session hint is kept for the run")

  local once = approval.new { port = spy { allow = true, remember = "once" } }
  local g = shaped(once:check { tool = "write", ask = true })
  assert(g.allowed and g.remembered == false, "and once is not")
end

function T.a_function_matcher_sees_the_value_and_the_arguments()
  local seen
  local gate = approval.new {
    port = spy("no"),
    policy = { { allow = true, tool = "grep", when = { pattern = function (v, args)
      seen = { v = v, path = args.path }
      return #v < 200
    end } } },
  }
  local d = shaped(gate:check { tool = "grep", args = { pattern = "needle", path = "src" }, ask = true })
  assert(d.allowed and d.source == "policy", "a short pattern is allowed")
  assert(seen.v == "needle" and seen.path == "src", "the matcher saw both")
  local long = shaped(gate:check { tool = "grep", args = { pattern = string.rep("n", 300) }, ask = true })
  assert(long.allowed == false and long.source == "port", "a long one falls through")
end

function T.a_policy_with_no_tool_covers_every_tool()
  local gate = approval.new { policy = { { deny = true } } }
  for _, name in ipairs { "read", "write", "shell" } do
    local d = shaped(gate:check { tool = name, ask = false })
    assert(d.allowed == false and d.policy == 1, "every tool, every argument: " .. name)
  end
end

function T.a_tool_list_narrows_a_policy()
  local gate = approval.new {
    port = spy("no"),
    policy = { { allow = true, tool = { "read", "list" } } },
  }
  assert(gate:check{ tool = "read", ask = true }.allowed, "a listed tool")
  assert(gate:check{ tool = "list", ask = true }.allowed, "and another")
  assert(gate:check{ tool = "write", ask = true }.allowed == false, "but not an unlisted one")
end

function T.numbers_and_booleans_key_the_same_way_every_time()
  local gate = approval.new { port = spy("no") }
  assert(gate:remember("read", true, "args", { n = 1, ok = true }), "an integer keys")
  local d = shaped(gate:check { tool = "read", args = { n = 1.0, ok = true }, ask = true })
  assert(d.allowed and d.source == "memory", "and a float of the same value is the same key")
  local e = shaped(gate:check { tool = "read", args = { n = 2, ok = true }, ask = true })
  assert(e.allowed == false, "a different number is a different call")
end


-- ------------------------------------------------------------------ the verify pass
--
-- Eleven claims the specification makes that nothing above was reading. Each one
-- was found by mutating the implementation and watching the suite stay green.

function T.a_non_boolean_ask_flag_still_asks()
  -- `ask` is documented as a boolean, so anything else is a harness bug. It must
  -- lean towards the port, never past it: reading only `== true` as "asks" would
  -- turn a host's stray 1 into a silent allow, which is the one direction §4
  -- forbids.
  for _, flag in ipairs { 1, "true", "false", 0, {} } do
    local port = spy("no")
    local gate = approval.new { port = port }
    local d = shaped(gate:check { tool = "shell", ask = flag })
    assert(d.allowed == false, "a truthy non-boolean ask is not a licence: " .. type(flag))
    assert(d.source == "port" and d.asked, "it reaches the operator instead: " .. d.source)
    assert(#port.asks == 1, "once")
  end
  local plain = approval.new { port = spy("no") }
  assert(plain:check{ tool = "shell", ask = false }.source == "flag", "and false still means false")
  assert(plain:check{ tool = "shell" }.source == "flag", "and so does an absent flag")
end

function T.the_memory_is_read_before_the_allow_policies()
  -- Step 4 sits above step 5, so a refusal the operator gave this run cannot be
  -- undone by an allow entry further down the declaration file.
  local port = spy("yes")
  local gate = approval.new {
    port = port,
    policy = { { allow = true, tool = "write" } },
  }
  assert(gate:remember("write", false), "the operator said never")
  local d = shaped(gate:check { tool = "write", args = { path = "a" }, ask = true })
  assert(d.allowed == false, "an allow policy does not reopen what the operator closed")
  assert(d.source == "memory", "and the log says which: " .. d.source)
  assert(#port.asks == 0, "without asking again")
end

function T.a_refusal_in_the_memory_wins_over_an_allow_in_it()
  -- Two keys can both hit. The answer must not depend on which was stored first.
  for _, order in ipairs { "wide first", "narrow first" } do
    local port = spy("yes")
    local gate = approval.new { port = port }
    if order == "wide first" then
      assert(gate:remember("write", true, "tool"))
      assert(gate:remember("write", false, "args", { path = "secret" }))
    else
      assert(gate:remember("write", false, "args", { path = "secret" }))
      assert(gate:remember("write", true, "tool"))
    end
    local d = shaped(gate:check { tool = "write", args = { path = "secret" }, ask = true })
    assert(d.allowed == false, "nothing in the memory widens what another part closed (" .. order .. ")")
    assert(d.source == "memory" and #port.asks == 0, d.source)
    local other = shaped(gate:check { tool = "write", args = { path = "notes" }, ask = true })
    assert(other.allowed and other.source == "memory", "and the wide allow still covers the rest")
  end
end

function T.two_argument_sets_never_share_a_memory_key()
  -- Every piece of the key is length-prefixed. Without that, an argument name
  -- carrying the separator would let one remembered answer speak for another.
  local port = spy("no")
  local gate = approval.new { port = port }
  assert(gate:remember("read", true, "args", { a = "1", b = "2" }), "one answer is kept")
  local forged = shaped(gate:check { tool = "read", args = { ["a=s1|b"] = "2" }, ask = true })
  assert(forged.allowed == false and forged.source == "port",
    "a forged argument name does not inherit it: " .. forged.source)
  local also = shaped(gate:check { tool = "read", args = { ["a|b"] = "1|2" }, ask = true })
  assert(also.allowed == false and also.source == "port", "nor does another shape of it")
  local real = shaped(gate:check { tool = "read", args = { a = "1", b = "2" }, ask = true })
  assert(real.allowed and real.source == "memory", "while the answer it was given still holds")
end

function T.a_whole_port_table_is_read_as_well_as_its_slice()
  -- spec/port.md wires this as p.ask.request. All three shapes count as wired,
  -- and nothing else does.
  local seen
  local gate = approval.new { port = { ask = { request = function (q) seen = q; return "yes" end } } }
  local d = shaped(gate:check { tool = "write", args = { path = "a" }, ask = true })
  assert(d.allowed and d.source == "port" and d.asked, "p.ask.request answers")
  assert(seen.tool == "write" and seen.trust == "ask", "and was handed the request")
  assert(not pcall(approval.new, { port = { ask = {} } }), "an ask table with no request is a wiring bug")
  assert(not pcall(approval.new, { port = { ask = { request = "yes" } } }), "and neither is a string")
end

function T.arguments_that_raise_when_read_are_a_denial_not_a_crash()
  -- The last resort. An argument table that misbehaves when it is read must not
  -- become an exception in the middle of a permission check.
  local hostile = setmetatable({}, { __index = function () error("the host object is gone", 0) end })
  local port = spy("yes")
  local gate = approval.new {
    port = port,
    policy = { { deny = true, tool = "write", when = { path = "^/" } } },
  }
  local ok, d = pcall(gate.check, gate, { tool = "write", args = hostile, ask = false })
  assert(ok, "no error escapes check")
  shaped(d)
  assert(d.allowed == false, "an unreadable request is a refusal")
  assert(d.source == "malformed", "flagged for the session log: " .. d.source)
  assert(has(d.reason, "could not read this request"), d.reason)
  -- and the gate is not wedged afterwards
  local after = shaped(gate:check { tool = "write", args = { path = "a" }, ask = true })
  assert(after.allowed and after.asked, "the in-flight flag was cleared on the way out")
end

function T.the_request_carries_the_deadline_and_a_bounded_reason()
  local port = spy("yes")
  local gate = approval.new { port = port }
  gate:check { tool = "write", ask = true, reason = string.rep("m", 100000), deadline = 1234.5 }
  local q = port.asks[1]
  assert(q.deadline == 1234.5, "the deadline is passed to the port untouched: " .. tostring(q.deadline))
  assert(type(q.reason) == "string" and #q.reason <= 400,
    "and the model's own reason is bounded before it is handed on: " .. tostring(q.reason and #q.reason))
  gate:check { tool = "write", ask = true, deadline = "soon", reason = 7 }
  assert(port.asks[2].deadline == nil, "a deadline that is not a number is dropped")
  assert(port.asks[2].reason == nil, "and so is a reason that is not a string")
end

function T.remembering_the_same_key_twice_keeps_its_place()
  -- A session log should read as a list of decisions, not of keystrokes.
  local gate = approval.new()
  assert(gate:remember("read", true))
  assert(gate:remember("write", false))
  assert(gate:remember("read", false), "the operator changed their mind")
  local held = gate:remembered()
  assert(#held == 2, "one answer per key, not one per keystroke: " .. #held)
  assert(held[1].tool == "read" and held[2].tool == "write", "in the order the memories were made")
  assert(held[1].allowed == false, "with the later answer")
  assert(gate:forget("read") == 1, "and one memory to drop, not two")
  assert(#gate:remembered() == 1, "leaving the other")
end

function T.an_unreadable_scope_is_a_refusal_not_a_default()
  -- Honouring a scope the gate cannot read is the widening direction, so it does
  -- not fall back to "tool": it refuses and names what came back.
  local port = spy { answer = "always", scope = "everything" }
  local gate = approval.new { port = port }
  local d = shaped(gate:check { tool = "write", args = { path = "a" }, ask = true })
  assert(d.allowed == false, "an unreadable scope is not honoured")
  assert(d.source == "port" and d.asked, d.source)
  assert(has(d.reason, "everything"), "and the host's bug is visible: " .. d.reason)
  assert(#gate:remembered() == 0, "nothing was stored")
  local good = approval.new { port = spy { answer = "always", scope = "args" } }
  local e = shaped(good:check { tool = "write", args = { path = "a" }, ask = true })
  assert(e.allowed and e.remembered and e.scope == "args", "while a scope it can read narrows the answer")
end

function T.forget_with_a_bad_tool_name_drops_nothing()
  local gate = approval.new()
  assert(gate:remember("read", true))
  for _, bad in ipairs { 7, true, "unheard-of" } do
    local ok, dropped = pcall(gate.forget, gate, bad)
    assert(ok, "forget never raises: " .. type(bad))
    assert(dropped == 0, "and a name that matches nothing drops nothing: " .. type(bad))
  end
  assert(#gate:remembered() == 1, "the memory is intact")
  assert(gate:forget() == 1, "and forget with no name still drops it")
end

function T.a_nonsense_answer_names_no_address()
  -- A reason that differs between runs cannot be asserted on, and an address in
  -- the transcript is a leak of the host's memory layout into the model's context.
  local one = approval.new { port = spy({ 1, 2, 3 }) }
  local two = approval.new { port = spy(setmetatable({}, { __tostring = function () return "0xdeadbeef" end })) }
  local a = shaped(one:check { tool = "write", ask = true })
  local b = shaped(two:check { tool = "write", ask = true })
  assert(a.allowed == false and b.allowed == false, "both are refusals")
  assert(a.reason == b.reason, "two different tables read the same way: " .. a.reason .. " / " .. b.reason)
  assert(not has(a.reason, "0x") and not has(b.reason, "0x"), "and neither prints an address")
  local fn = approval.new { port = { ask = function () return function () end end } }
  local c = shaped(fn:check { tool = "write", ask = true })
  assert(c.allowed == false and not has(c.reason, "0x"), c.reason)
  assert(has(c.reason, "a function"), "a function answer is named by its type: " .. c.reason)
end

function T.an_unknown_option_is_caught_at_construction()
  -- The same defect a misspelt policy key is: the gate would build, hold no
  -- policies, and quietly permit what the declaration meant to stop.
  local _, typo = pcall(approval.new, { policies = { { deny = true, tool = "shell" } } })
  assert(type(typo) == "string" and has(typo, "policies"), tostring(typo))
  assert(not pcall(approval.new, { prt = { ask = function () return "no" end } }), "a misspelt port")
  assert(not pcall(approval.new, { trusted = true }), "a misspelt trust")
  assert(pcall(approval.new, { port = { ask = function () return "no" end }, policy = {}, trust = "none" }),
    "while the three it takes are fine")
end


-- ------------------------------------------------------------------ 53-54, a question trust cannot waive

function T.always_is_asked_under_trust_and_under_an_allow_policy()
  -- §2.3, amended 2026-09-12: `always` goes from the memory straight to the port.
  local port = spy("no")
  local gate = approval.new { port = port, trust = "trusted" }
  local d = shaped(gate:check { tool = "mode", args = { to = "writing" }, ask = true, always = true })
  assert(d.allowed == false and d.source == "port" and d.asked == true, d.source .. " " .. d.reason)
  assert(#port.asks == 1 and port.asks[1].tool == "mode", "the port was asked")
  d = shaped(gate:check { tool = "mode", args = { to = "writing" }, ask = true })
  assert(d.allowed and d.source == "trust", "without always, trust answers: " .. d.source)
  assert(#port.asks == 1, "and the port is not asked")

  port = spy("yes")
  gate = approval.new { port = port, policy = { { allow = true, tool = "mode" } } }
  d = shaped(gate:check { tool = "mode", args = {}, ask = true, always = true })
  assert(d.allowed and d.source == "port" and d.asked == true, d.source)
  d = shaped(gate:check { tool = "mode", args = {}, ask = true })
  assert(d.allowed and d.source == "policy", "without always, the policy answers: " .. d.source)
  assert(#port.asks == 1, "one question in all")
end

function T.always_still_loses_to_a_deny_and_to_a_never()
  local port = spy("yes")
  local gate = approval.new { port = port, trust = "trusted", policy = { { deny = true, tool = "mode" } } }
  local d = shaped(gate:check { tool = "mode", args = {}, ask = true, always = true })
  assert(d.allowed == false and d.source == "policy" and #port.asks == 0, d.source)

  port = spy(function () return "never" end)
  gate = approval.new { port = port, trust = "trusted" }
  d = shaped(gate:check { tool = "mode", args = { to = "x" }, ask = true, always = true })
  assert(d.allowed == false and d.source == "port" and d.remembered, d.source)
  d = shaped(gate:check { tool = "mode", args = { to = "x" }, ask = true, always = true })
  assert(d.allowed == false and d.source == "memory" and #port.asks == 1, d.source)
end

return T
