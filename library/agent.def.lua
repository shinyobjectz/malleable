---@meta
--
-- The declaration surface, for an editor. LuaLS annotations only: this file is never
-- loaded, is not on `package.path`, and cannot run. There is no SDK, no constructor and
-- no loader -- a declaration is plain annotated Lua and this is the annotation.
--
-- CHECKED IN, NOT GENERATED. A generated file would document what the code happens to do;
-- the promise is `spec/`, and this file states the promise. What keeps it from becoming a
-- lie with autocomplete is `test/definition_test.lua`, which enumerates the keys of the
-- real `agent` and `interpret` tables and fails if this file omits one or names one that
-- does not exist.
--
-- Point an editor at it with a `.luarc.json` beside your declarations:
--
--     { "workspace.library": ["path/to/malleable/library"] }

---------------------------------------------------------------------- argument types

---@class agent.arg
---@field type string
---@field about string
---@field optional boolean|nil

---------------------------------------------------------------------------- a tool

---@class agent.tool.decl
---@field about string        one sentence: what it is for, and when to reach for it
---@field args table<string, agent.arg>|nil
---@field ask boolean|agent.ask.edit|nil  put it to the human before the body runs
---@field requires agent.requirement[]|nil what a call must meet before it runs
---@field preview boolean|nil a host may show the arguments before the tool runs
---@field run fun(c: agent.ctx): any, string|nil

---@class agent.ask.edit
---@field edit string|string[]  the arguments the person may change before approving

---@class agent.requirement
---@field says string            told to the model with the tool's about, and the reason a call fails
---@field check fun(c: agent.ctx): boolean, string|nil
---@field check_only boolean|nil checked, never told to the model

---@class agent.store.decl
---@field about string          what one row is
---@field columns table<string, agent.arg>
---@field sort string|string[]|nil  the columns a listing is sorted by first

---@class agent.port.store
---@field rows fun(store: string): table[]
---@field add fun(store: string, row: table): boolean|nil, string|nil
---@field change fun(store: string, where: table, set: table): integer|nil, string|nil
---@field remove fun(store: string, where: table): integer|nil, string|nil

---@class agent.ctx
---@field args table<string, any>
---@field fs agent.port.fs
---@field sh agent.port.sh
---@field clock agent.port.clock
---@field log agent.port.log
---@field store agent.port.store  the program's declared stores (src/store.lua)
---@field note fun(text: string)
---@field history table|nil  the kept runs, read only: find, recall, evidence, kept, line
---@field world table

---------------------------------------------------------------------------- the ports

---@class agent.port.fs
---@field read fun(path: string): string|nil, table|nil
---@field write fun(path: string, text: string): boolean|nil, table|nil
---@field list fun(dir: string): table|nil, table|nil
---@field remove fun(path: string): boolean|nil, table|nil
---@field exists fun(path: string): boolean

---@class agent.port.sh
---@field run fun(argv: string[]|string, opts: table|nil): table|nil, table|nil

---@class agent.port.clock
---@field now fun(): number
---@field mono fun(): number
---@field sleep fun(secs: number)

---@class agent.port.ask
---@field request fun(q: table): table

---@class agent.port.log
---@field write fun(level: string, event: string, fields: table|nil)

---@class agent.port
---@field model table
---@field fs agent.port.fs
---@field sh agent.port.sh
---@field clock agent.port.clock
---@field ask agent.port.ask
---@field log agent.port.log
---@field skills table|nil
---@field ledger table|nil
---@field mcp table|nil
---@field history table|nil   where runs are kept (spec/history.md); a tool body gets a view that reads

---------------------------------------------------------------------------- a result

---@class agent.result
---@field stop string           "answered" | "budget" | "refused" | "error"
---@field reason string|nil
---@field answer string|nil
---@field steps integer
---@field transcript table[]
---@field calls agent.call[]
---@field notes string[]

---@class agent.call
---@field step integer
---@field id string
---@field tool string
---@field args table
---@field ok boolean
---@field output string
---@field asked boolean
---@field refused boolean|nil

---------------------------------------------------------------------- a feature file

---@class agent.step.decl
---@field given fun(c: agent.step.given)|nil   it writes the world
---@field then_ fun(c: agent.step.then): boolean|nil, string|nil   it reads the result

---@class agent.step.given
---@field args any[]
---@field doc string|nil
---@field rows string[][]|nil
---@field world table          the world as configured; writing it is the point

---@class agent.step.then
---@field args any[]
---@field doc string|nil
---@field rows string[][]|nil
---@field world table          the world as it ended up, read-only
---@field result agent.result|nil

---@class agent.report
---@field passed integer
---@field failed integer
---@field undefined integer
---@field broken integer
---@field skipped integer
---@field ok boolean
---@field vocabulary integer
---@field scenarios table[]

---------------------------------------------------------------------------- the prefix

---@class agent
local agent = {}

-- what the agent is ------------------------------------------------------------------

---@param v string
---@return agent
function agent.name(v) end
---@param v string
---@return agent
function agent.model(v) end
---@param v string
---@return agent
function agent.system(v) end
---@param v integer
---@return agent
function agent.budget(v) end
---@param v "none"|"low"|"medium"|"high"  how hard the model thinks before it answers
---@return agent
function agent.reasoning(v) end

-- its standing permission policy -------------------------------------------------------

---@param v string  "trusted" | "ask" | "none"
function agent.trust(v) end
---@param v string|string[]
function agent.allow(v) end
---@param v string|string[]
function agent.deny(v) end

-- a tool, a hook, a step ---------------------------------------------------------------

---@param name string
---@param decl agent.tool.decl|nil
---@return any
function agent.tool(name, decl) end

---@param event string  "start" | "step" | "call" | "result" | "stop"
---@param fn fun(e: table)|nil
---@return any
function agent.on(event, fn) end

--- A step of a feature file. It declares its phase by which body it gives, `given` or
--- `then_`, and gives exactly one. There is no `when`: the three ways a run starts are
--- the harness's (rule 6).
---@param expression string
---@param decl agent.step.decl|nil
---@return any
function agent.step(expression, decl) end

-- a procedure a person wrote, a beat, a server -----------------------------------------

---@param name string
---@param decl table|nil
---@return any
function agent.skill(name, decl) end
---@param name string
---@param decl table|nil
---@return any
function agent.every(name, decl) end
---@param name string
---@param decl table|nil
---@return any
function agent.uses(name, decl) end
---@param name string
---@param decl agent.store.decl|nil
---@return any
function agent.store(name, decl) end

-- argument types -----------------------------------------------------------------------

---@param about string
---@return agent.arg
function agent.string(about) end
---@param about string
---@return agent.arg
function agent.number(about) end
---@param about string
---@return agent.arg
function agent.boolean(about) end
---@param about string
---@return agent.arg
function agent.table(about) end
---@param about string
---@return agent.arg
function agent.list(about) end
---@param about string
---@return agent.arg
function agent.string_opt(about) end
---@param about string
---@return agent.arg
function agent.number_opt(about) end
---@param about string
---@return agent.arg
function agent.boolean_opt(about) end
---@param about string
---@return agent.arg
function agent.table_opt(about) end
---@param about string
---@return agent.arg
function agent.list_opt(about) end
--- A string from a closed list: `agent.one_of "why" { "near", "far" }`.
---@param about string|string[]
---@return agent.arg|fun(choices: string[]): agent.arg
function agent.one_of(about) end
---@param about string|string[]
---@return agent.arg|fun(choices: string[]): agent.arg
function agent.one_of_opt(about) end

-- the toolkits -------------------------------------------------------------------------

---@param cfg table
function agent.files(cfg) end
---@param cfg table
function agent.shell(cfg) end
---@param cfg table|nil
function agent.plan(cfg) end
--- history, recall and evidence: the tools that read the runs the world has kept.
function agent.history() end
--- A kit of the workspace's own (docs/spec/kit.md): its table, loaded for the process, and
--- installed on this agent with `told`, what its lines would have said.
---@param def table
---@param told table|nil
function agent.kit(def, told) end

---@param name string
---@param cfg table|nil
---@return any
function agent.delegate(name, cfg) end

-- the clock, and the declared servers ---------------------------------------------------

---@param port agent.port
---@param opts table|nil
---@return table
function agent.tick(port, opts) end
---@param port agent.port
---@param opts table|nil
---@return table
function agent.due(port, opts) end
---@param port agent.port
---@param opts table|nil
---@return table
function agent.connect(port, opts) end

-- running it, and looking at it first ---------------------------------------------------

---@param prompt string
---@param port agent.port
---@param opts table|nil
---@return agent.result
function agent.run(prompt, port, opts) end

--- A conversation: a fast talker in front, this agent behind it doing the work as
--- background jobs (spec/speech.md). Callable, and the speech module too:
--- `agent.speech { world = port }`, `agent.speech.talker { model = ... }`.
---@type table|fun(cfg: { world: agent.port, workers: table|nil, talker: table|nil, job_world: table|function|nil, clock: function|nil, keep: integer|nil, jobs: integer|nil, job_budget: integer|nil, proactive: boolean|nil, settle: number|nil, relay: boolean|nil }): table
agent.speech = {}

---@param port agent.port
---@param opts table|nil
---@return boolean, string[]|nil
function agent.check(port, opts) end

---@return table
function agent.schema() end

---@return string[]
function agent.problems() end

---@return table
function agent.spec() end

-- the behaviour half ---------------------------------------------------------------------

--- What the agent IS, from a feature file: the is lines of its Background applied to this
--- agent, as the `agent.*` statements they name (spec/declare.md). Raises with the line on
--- a file it will not read.
---@param text string   the text of a .feature file
---@param opts table|nil  { read = function (path) -> text } for a file a line names
---@return table        the prefix
function agent.declare(text, opts) end

--- Run a feature file against this declaration, on the doubles.
---@param feature string   the text of a .feature file
---@param opts table|nil
---@return agent.report|nil, string|nil
function agent.verify(feature, opts) end

--- The problems a run would hit, as sentences, reaching no port at all.
---@param feature string
---@return string[]
function agent.check_feature(feature) end

--- The same feature file against a real model, k times per scenario, answering a rate.
--- The world stays doubled; only the model is real.
---@param feature string
---@param model table    the host's model port
---@param opts table|nil  { samples = 20 }
---@return agent.report|nil, string|nil
function agent.evaluate(feature, model, opts) end

--- The built-in step vocabulary: expression, phase and one sentence each.
---@return table[]
function agent.steps() end

-- an approval gate, the port it binds into, the doubles -------------------------------------

---@param opts table|nil
---@return table
function agent.gate(opts) end
---@param port agent.port
---@param gate table|nil
---@param opts table|nil
---@return agent.port, string[]
function agent.bind(port, gate, opts) end
---@param cfg table|nil
---@return agent.port
function agent.world(cfg) end

--- A whole world with nothing from the host: a working shell over a filesystem in memory,
--- a frozen clock, a gate that refuses by default, a log, and a model that says plainly it
--- is not there. This is the embed door -- `agent.world` is the test double.
---@param cfg table|nil
---@return agent.port
function agent.sandbox(cfg) end

-- a second agent in one process; start this one over -----------------------------------------

---@return agent
function agent.new() end
---@return agent
function agent.reset() end

--- The four ways a run ends, as a fixed list.
agent.stops = {}

-- the rest of the tree, named on the prefix so there is still one thing to remember -----------

agent.approval = {}
agent.behaviour = {}
agent.change = {}
agent.cli = {}
agent.compaction = {}
agent.config = {}
agent.declared = {}
agent.double = {}
agent.gherkin = {}
agent.interpret = {}
agent.mcp = {}
agent.observe = {}
agent.port = {}
agent.provider = {}
agent.schedule = {}
agent.session = {}
agent.skills = {}
agent.subagent = {}
agent.tools_fs = {}
agent.trace = {}
agent.tools_sh = {}
agent.turn = {}
--- The table a port yields to wait on the host, a sleep or the person (spec/speech.md).
agent.wait = {}
agent.work = {}

---------------------------------------------------------------- the interpretive layer
--
-- `agent` declares behaviour; `interpret` declares reading. One prefix each. There is no
-- field anywhere below that can hold a regex, and that is the whole design: a mark is
-- assembled from parts, every shape is a constant held by identity, and a reading of
-- ordinary language cannot be written here at all -- it belongs to the map.

---@class interpret
local interpret = {}

---@param name string
---@param decl table|nil
---@return any
function interpret.mark(name, decl) end
---@param name string
---@param decl table|nil
---@return any
function interpret.seam(name, decl) end
---@param name string
---@param decl table|nil
---@return any
function interpret.law(name, decl) end
---@param name string
---@param decl table|nil
---@return any
function interpret.lint(name, decl) end
---@param name string
---@param decl table|nil
---@return any
function interpret.book(name, decl) end

---@param name string
---@return any
function interpret.means(name) end
---@return table
function interpret.rules() end
---@return string
function interpret.render() end
---@param path string
---@return any
function interpret.render_file(path) end
---@param text string
---@return any
function interpret.load(text) end
---@return any
function interpret.reset() end
---@param name string
---@return any
function interpret.refused_by_map(name) end

-- The closed vocabularies. Each is a table held by IDENTITY, never a string: a typo
-- yields nil and nil is refused by name, loudly, at declaration.
interpret.SHOUTED = {}
interpret.WORD = {}
interpret.NUMBER = {}
interpret.DATE = {}
interpret.LINE_START = {}
interpret.VALUE = {}
interpret.FLAG = {}
interpret.AGENT = {}
interpret.BUILD = {}
interpret.CONTEXTUAL = {}
interpret.FUNCTIONAL = {}
interpret.HOST = {}
interpret.MIDDLE = {}
interpret.STEP = {}
interpret.STORE = {}

return agent
