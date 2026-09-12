Feature: modes rails
  What a rail must survive (docs/spec/kit.md): the doubles script exactly the sequence a
  real author took on 2026-09-12, which the first draft of the modes kit failed: move, verify
  the notebook (a second user of the kit, in a nested run), edit. And a check-only scenario
  followed by a run. The first draft, kept as test/fixtures/modes-v1.lua, fails both here;
  test/kit_test.lua proves it. Deterministic; run with --verify. The other rails are their
  own files: modes-trusted (trust), modes-policy (an allow policy), modes-pinned (a deny),
  modes-edges (a delegate, a budget, a move to the mode it is in).

  Background:
    Given the agent is called author
    And its model is "openrouter:z-ai/glm-5.3"
    And its reasoning is low
    And it is briefed:
      """
      You edit the feature files under agents/, which declare the agents you work beside, including yourself.
      How to work: features lists the files; feature reads one with line numbers; vocabulary lists every line a file may hold. Read the file before you edit it. Make one edit at a time, and verify after each.
      Which tool: edit for anything that widens nothing (a briefing, a budget, what a tool is for, a narrowing line such as a glob or a limit, a proposed scenario, a shorthand). propose for anything that widens what the agent can reach (a tool, a body, commands, the workspace, a delegate, a server, a beat, a wider glob) and for a new file; propose asks the person, and no means no.
      The wall: a gate (asks first) is never removed, a narrowing line is never removed or widened, and an authored scenario is never changed or withdrawn. If you are asked to, do not try: say why not.
      How to send an edit: op add takes the new line as line. op replace takes the old line as line and the new one as with. A line's doc string goes in doc and its table in rows. A scenario goes whole in text, starting with Scenario:. Send a line as it reads in the file, without its number or its keyword.
      You begin in the mode reading, where you may read and verify. To edit, move to the mode editing with the mode tool, which asks the person.
      Answer briefly: what you changed, in which file, and whether its scenarios pass.
      """
    And it edits agents in "agents"
    And it uses the kit "../library/modes.lua"
    And it starts in the mode reading
    And in the mode reading it may call "features, feature, vocabulary, verify"
    And in the mode editing it may call "features, feature, vocabulary, verify, edit, propose"
    And the mode reading moves to editing when the person says so
    And the human approves mode
    And the file "agents/modes.lua" contains:
      """
      -- modes -- a state machine over what an agent may call, moved only by the person.
      -- A kit (docs/spec/kit.md); the contract is docs/spec/modes.md.
      --
      --     And it uses the kit "../library/modes.lua"
      --     And it starts in the mode reading
      --     And in the mode reading it may call "features, feature, vocabulary, verify"
      --     And in the mode editing it may call "features, feature, vocabulary, verify, edit, propose"
      --     And the mode reading moves to editing when the person says so
      --
      -- Every run starts in the start; a call to a tool the mode does not list is refused with a
      -- sentence the model reads; the `mode` tool, which asks first, is the only way to move.

      local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

      local function split(text)
        local out = {}
        for part in tostring(text):gmatch("[^,]+") do
          local p = trim(part)
          if p ~= "" then out[#out + 1] = p end
        end
        return out
      end

      local function mode_of(told, name, line)
        told.modes = told.modes or {}
        told.order = told.order or {}
        local m = told.modes[name]
        if not m then
          m = { name = name, list = nil, allowed = {}, moves = {}, move_order = {} }
          told.modes[name] = m
          told.order[#told.order + 1] = name
        end
        return m
      end

      -- The state is PER USE, in the install's closure: two agents in one process that both use
      -- the kit (an author and the file it verifies) each keep their own mode, and a verify the
      -- author runs on the notebook does not move the author. A start a given line asked for
      -- rides on the world as `mode` and reaches the start hook as `e.given.mode`, so nothing
      -- leaks from a scenario that ran nothing into the next run. `last` is the use of the
      -- OUTERMOST run: a Then line reads the agent the scenario asked, not the notebook it
      -- verified in a nested run (found by evals/modes-rails.feature, 2026-09-12: reading the
      -- run that started most recently read the nested one). `running` is the stack of uses
      -- whose runs are open; `stop` pops it, on every path out of a run.
      local last, running = nil, {}

      return {
        name  = "modes",
        -- the doubles scenarios its rail survives, beside this file (docs/spec/kit.md); a
        -- delegate under a mode starts fresh, in no mode of its own unless its file says one
        rails = { "../evals/modes-rails.feature", "../evals/modes-trusted.feature", "../evals/modes-policy.feature",
                  "../evals/modes-pinned.feature", "../evals/modes-edges.feature" },
        delegate = "fresh",
        about = "a state machine over what the agent may call, moved only by the person",

        is = {
          -- a gate: an agent may add the start and never remove or replace it, or a self-edit
          -- from reading to editing would be a widening the wall scores as nothing
          { expr = "it starts in the mode {word}", reach = "neither", gate = true,
            about = "the mode every run begins in; never removed or changed by an agent",
            tells = function (told, name)
              if told.start then error("the start is said twice: " .. told.start .. " and " .. name, 0) end
              told.start = name
            end },
          { expr = "in the mode {word} it may call {string}", reach = "narrows",
            about = "the tools that mode may call, a comma list; every other call is refused",
            -- the same mode with fewer tools is narrower still, so the wall lets an agent shorten
            -- its own list without a proposal (and never lengthen it)
            narrower = function (old, new)
              if old[1] ~= new[1] then return false end
              local had = {}
              for _, t in ipairs(split(old[2])) do had[t] = true end
              local list = split(new[2])
              if #list == 0 then return false end
              for _, t in ipairs(list) do if not had[t] then return false end end
              return true
            end,
            tells = function (told, name, list)
              local m = mode_of(told, name)
              if m.list then error("the mode " .. name .. " is declared twice", 0) end
              m.list = split(list)
              if #m.list == 0 then error("the mode " .. name .. " lists no tool", 0) end
              for _, t in ipairs(m.list) do m.allowed[t] = true end
            end },
          { expr = "the mode {word} moves to {word} when the person says so", reach = "widens",
            about = "a move the person may approve",
            tells = function (told, from, to)
              told.moves = told.moves or {}
              told.moves[#told.moves + 1] = { from = from, to = to }
            end },
        },

        install = function (told, agent)
          local modes = told.modes or {}
          if not told.start then error("say which mode it starts in: `it starts in the mode <name>`", 0) end
          if not modes[told.start] or not modes[told.start].list then
            error("it starts in the mode " .. told.start .. ", which no `in the mode " .. told.start .. " it may call` line declares", 0)
          end
          for _, m in ipairs(told.order or {}) do
            if not modes[m].list then error("the mode " .. m .. " is named and never declared", 0) end
          end
          for _, mv in ipairs(told.moves or {}) do
            for _, side in ipairs { mv.from, mv.to } do
              if not modes[side] or not modes[side].list then
                error("the move from " .. mv.from .. " to " .. mv.to .. " names " .. side .. ", which is not a mode", 0)
              end
            end
            local m = modes[mv.from]
            if not m.moves[mv.to] then
              m.moves[mv.to] = true
              m.move_order[#m.move_order + 1] = mv.to
            end
          end

          local names = {}
          for _, n in ipairs(told.order) do names[#names + 1] = n end
          local moves_text = {}
          for _, n in ipairs(told.order) do
            if #modes[n].move_order > 0 then
              moves_text[#moves_text + 1] = "from " .. n .. " to " .. table.concat(modes[n].move_order, " or ")
            end
          end

          local function tools_of(name) return table.concat(modes[name].list, ", ") end
          local use = { current = nil }

          agent.on("start", function (e)
            local asked = type(e) == "table" and type(e.given) == "table" and e.given.mode or nil
            use.current = (asked and modes[asked] and asked) or told.start
            running[#running + 1] = use
            last = running[1]
            return nil
          end)

          agent.on("stop", function ()
            running[#running] = nil
            return nil
          end)

          agent.on("call", function (e)
            if e.tool == "mode" then return nil end
            local current = use.current
            local m = current and modes[current]
            if m and not m.allowed[e.tool] then
              return { allow = false, why = "in the mode " .. current .. " it may call only " .. tools_of(current)
                .. "; to call " .. tostring(e.tool) .. ", move to another mode with the mode tool, which asks the person" }
            end
            return nil
          end)

          -- one_of lists at least two values; one mode alone has nowhere to move, and the
          -- second choice is refused by the body as no mode
          local choices = {}
          for _, n in ipairs(names) do choices[#choices + 1] = n end
          if #choices < 2 then choices[2] = choices[1] .. "_" end
          local one_of = agent.one_of "the mode to move to"
          agent.tool("mode", {
            about = "Move to another mode, which changes what you may call. It starts in the mode " .. told.start
              .. "; " .. (#moves_text > 0 and ("the moves are " .. table.concat(moves_text, "; ")) or "there is no move")
              .. ". The person is asked.",
            ask = "always",
            args = { to = one_of(choices) },
            run = function (c)
              local to = c.args.to
              local from = use.current or told.start
              if not modes[to] or not modes[to].list then return nil, "there is no mode " .. tostring(to) end
              if to == from then return "already in the mode " .. to .. "; it may call " .. tools_of(to) end
              if not modes[from].moves[to] then
                local can = modes[from].move_order
                return nil, "from the mode " .. from .. " it may move to " .. (#can > 0 and table.concat(can, " or ") or "nothing")
                  .. ", not to " .. to
              end
              use.current = to
              return "in the mode " .. to .. "; it may call " .. tools_of(to)
            end,
          })
        end,

        steps = {
          { expr = "the run begins in the mode {word}",
            given = function (c) c.world.mode = c.args[1] end },
          { expr = "it is in the mode {word}",
            then_ = function (c)
              local current = last and last.current
              if current ~= c.args[1] then return false, "it is in the mode " .. tostring(current) end
            end },
        },

        says = function (told)
          local out = {}
          if told.start then out[#out + 1] = "it starts in the mode " .. told.start end
          for _, n in ipairs(told.order or {}) do
            local m = told.modes[n]
            -- single quotes on purpose: this file is also carried inside a feature's doc string,
            -- where a backslash before a quote is read as an escape and the text changes
            if m.list then out[#out + 1] = 'in the mode ' .. n .. ' it may call "' .. table.concat(m.list, ", ") .. '"' end
          end
          for _, mv in ipairs(told.moves or {}) do
            out[#out + 1] = "the mode " .. mv.from .. " moves to " .. mv.to .. " when the person says so"
          end
          return out
        end,
      }
      """
    And the file "agents/notebook.feature" contains:
      ```
      Feature: notebook
        Reads and keeps the person's notes, as markdown files under notes/.

        Background:
          Given the agent is called notebook
          And its model is "openrouter:z-ai/glm-5.3"
          And its reasoning is low
          And it is briefed:
            """
            You read and keep the person's notes, as markdown files under notes/. Look at what is there before you answer.
            """
          And it reads and writes the workspace
          And it never touches "secrets/**"
          And the tool write asks first
          And it uses the kit "modes.lua"
          And it starts in the mode reading
          And in the mode reading it may call "read, list"
          And in the mode writing it may call "read, list, write"
          And the mode reading moves to writing when the person says so

        Scenario: it reads a note
          Given the file "notes/budget.md" contains:
            """
            The venue costs 1200. Catering is 800.
            """
          And the model calls read with {"path": "notes/budget.md"}
          And the model answers "notes/budget.md: the venue is 1200 and catering 800."
          When the agent is asked "what does my budget note say?"
          Then it calls read
          And the answer says "1200"

        Scenario: it asks before it writes
          Given the human refuses write
          And the model calls write with {"path": "notes/todo.md", "text": "call the venue"}
          And the model answers "I did not write it: you said no."
          When the agent is asked "note that I must call the venue"
          Then the call to write is refused
      ```

  Scenario: two users of the kit in one process: the author's move survives a verify of the notebook
    Given the model calls mode with {"to": "editing"}
    And the model calls verify with {"path": "notebook.feature"}
    And the model calls edit with {"path": "notebook.feature", "op": "add", "line": "it never touches \"private/**\""}
    And the model answers "narrowed"
    When the agent is asked "keep the notebook out of private/"
    Then the human is asked about mode
    And the call to verify answers "passed"
    And it is in the mode editing
    And the call to edit answers "applied"
    And the file "agents/notebook.feature" holds the line "And it never touches \"private/**\""

  Scenario: a check-only scenario asks for a mode and runs nothing
    Given the run begins in the mode editing
    When the declaration is loaded
    Then the declaration is sound

  Scenario: and the next run starts in the start, not in the mode the check asked for
    Given the model calls edit with {"path": "notebook.feature", "op": "add", "line": "it never touches \"private/**\""}
    And the model answers "refused"
    When the agent is asked "keep the notebook out of private/"
    Then the call to edit is refused
    And it is in the mode reading
    And nothing is written
