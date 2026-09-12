-- command -- what a command line DID, as a term, so the command itself never travels.
--
-- Two halves, and only one of them can be wrong.
--
-- `parse` is TOTAL and structural: every simple command in the line, with its argv, its
-- redirections and the operator that joined it to the next. It never guesses meaning, and
-- a line it cannot place is a defect in this grammar rather than a shrug.
--
-- `act` is PARTIAL and measured: a term from the closed set in `command.ACTS`, or nothing.
-- Nothing is a GAP -- counted, reported, filed against the vocabulary, never repaired by
-- widening a pattern. A run whose commands are 40% unnamed says 40%.
--
-- The split is what makes this legitimate where a phrase reader over PROSE is not: the
-- language is closed and formal, the parse is total, and only the NAMING is partial --
-- with the partiality on the report instead of in a silence.
--
-- It requires nothing. Contract: spec/command.md. Amend that before this diverges.

local command = {}

-- the terms
--
-- Closed, and it stays small. The test of a term is that a Then line can FAIL on it.
-- `publishes`, `escalates`, `deletes` and `connects` carry the weight: an
-- agent that inspects a lot is working, and an agent that publishes is doing the thing
-- nobody can undo for it. No token count says that.

local ACTS = {
  "inspects", "reads", "writes", "deletes", "tests", "builds",
  "installs", "commits", "publishes", "connects", "escalates",
}

--- The closed set of terms, as a fresh list on every read.
setmetatable(command, {
  __index = function (_, k)
    if k ~= "ACTS" then return nil end
    local out = {}
    for i = 1, #ACTS do out[i] = ACTS[i] end
    return out
  end,
})

local KNOWN = {}
for i = 1, #ACTS do KNOWN[ACTS[i]] = true end

--- Is this a term this reader may answer?
function command.known(term)
  return KNOWN[term] == true
end

-- the grammar
--
-- Word splitting with quoting, the five operators that join simple commands, and
-- redirections. Nothing is expanded, substituted, globbed or evaluated: `rm -rf $TARGET`
-- is a `deletes` whose argument this reader cannot know, and claiming otherwise would be
-- inventing a fact about the run (spec/command.md, "What it must NOT do").

local OPERATORS = { "&&", "||", ";;", ";", "|&", "|", "&" }

local function is_space(ch)
  return ch == " " or ch == "\t" or ch == "\n" or ch == "\r"
end

local function operator_at(text, i)
  for k = 1, #OPERATORS do
    local op = OPERATORS[k]
    if text:sub(i, i + #op - 1) == op then return op end
  end
  return nil
end

-- One word, from `i`. Answers the word, where it ended, and whether it was quoted --
-- quoting matters because `"rm"` is still rm, and this reader must not be fooled by a
-- writer who quotes a program name, nor pretend a quoted argument is a program.
local function word_at(text, i)
  local out, n = {}, #text
  local quoted = false
  while i <= n do
    local ch = text:sub(i, i)
    if is_space(ch) or operator_at(text, i) then break end
    if ch == "'" then
      quoted = true
      local close = text:find("'", i + 1, true)
      if not close then return nil, i, "an unclosed single quote" end
      out[#out + 1] = text:sub(i + 1, close - 1)
      i = close + 1
    elseif ch == '"' then
      quoted = true
      local j = i + 1
      local buf = {}
      while j <= n do
        local c = text:sub(j, j)
        if c == "\\" and j < n then
          buf[#buf + 1] = text:sub(j + 1, j + 1)
          j = j + 2
        elseif c == '"' then
          break
        else
          buf[#buf + 1] = c
          j = j + 1
        end
      end
      if j > n then return nil, i, "an unclosed double quote" end
      out[#out + 1] = table.concat(buf)
      i = j + 1
    elseif ch == "\\" and i < n then
      out[#out + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out), i, nil, quoted
end

local REDIRECTS = { ">>", ">&", "<", ">" }

local function redirect_at(text, i)
  -- A leading digit is a file descriptor: `2>&1`.
  local j = i
  while text:sub(j, j):match("%d") do j = j + 1 end
  for k = 1, #REDIRECTS do
    local r = REDIRECTS[k]
    if text:sub(j, j + #r - 1) == r then return r, j + #r end
  end
  return nil
end

--- Every simple command in one line.
---
--- Answers a list of `{ argv, redirects, joined }` -- `joined` is the operator that
--- followed this command, or nil for the last. On a line the grammar cannot place it
--- answers nil, a sentence, and the byte it stopped at, which is what makes a gap here
--- reportable rather than a shrug.
function command.parse(line)
  if type(line) ~= "string" then
    error("command.parse(line): line is a string, and arrived as " .. type(line), 2)
  end
  local out = {}
  local current = { argv = {}, redirects = {} }
  local i, n = 1, #line

  local function close_current(op)
    if #current.argv > 0 or #current.redirects > 0 then
      current.joined = op
      out[#out + 1] = current
    end
    current = { argv = {}, redirects = {} }
  end

  while i <= n do
    local ch = line:sub(i, i)
    -- A here-document's BODY is on the lines AFTER the command, and this grammar is
    -- handed one line. Reading `<<EOF` as a redirection with the target `EOF` and the
    -- body as further commands is a wrong answer dressed as a right one, so it is
    -- refused by name -- and a refusal here is a gap the caller can report, which is the
    -- whole reason the parse half is total and says where it stopped.
    if line:sub(i, i + 1) == "<<" then
      return nil, "a here-document needs more than one line, and this reads one", i
    end
    if is_space(ch) then
      i = i + 1
    elseif ch == "(" or ch == ")" then
      -- A subshell's parentheses group commands; the commands inside are the ones that
      -- matter and they are read exactly as the ones outside are.
      close_current(nil)
      i = i + 1
    else
      local op = operator_at(line, i)
      if op then
        close_current(op)
        i = i + #op
      else
        local red, after = redirect_at(line, i)
        if red then
          -- The target is the next WORD, not the next byte: `> b.txt` and `>b.txt` are
          -- the same redirection, and reading from the space made the target empty and
          -- left the filename to be picked up as an argument on the next pass.
          while after <= n and is_space(line:sub(after, after)) do after = after + 1 end
          local target, at, why = word_at(line, after)
          if target == nil then return nil, why, at end
          if target == "" then return nil, "a redirection with no target", i end
          current.redirects[#current.redirects + 1] = { op = red, target = target }
          i = at
        else
          local w, at, why, quoted = word_at(line, i)
          if w == nil then return nil, why, at end
          if w ~= "" then
            current.argv[#current.argv + 1] = w
            if #current.argv == 1 then current.quoted_head = quoted == true end
          end
          i = at
        end
      end
    end
  end
  close_current(nil)
  return out
end

-- The naming: a table of programs, PARTIAL on purpose. A program not here is a gap, and
-- the gap is the number. Widening this table is a deliberate change made after reading a
-- report, never a pattern loosened to make one line pass.
--
-- Two shapes. A program whose whole job is one act names the act. A program with
-- subcommands -- git, npm, cargo, docker -- names a table keyed by the subcommand, with
-- `[1]` as what the bare program does when it has no subcommand this table knows.

local BY_PROGRAM = {
  -- reading state
  ls = "inspects", pwd = "inspects", whoami = "inspects", env = "inspects",
  ps = "inspects", df = "inspects", du = "inspects", stat = "inspects",
  find = "inspects", which = "inspects", uname = "inspects", date = "inspects",
  grep = "inspects", rg = "inspects", ag = "inspects", wc = "inspects",
  diff = "inspects", file = "inspects", tree = "inspects",

  -- reading contents
  cat = "reads", head = "reads", tail = "reads", less = "reads", more = "reads",
  jq = "reads", sed = "reads", awk = "reads",

  -- changing files
  touch = "writes", mkdir = "writes", cp = "writes", mv = "writes",
  ln = "writes", chmod = "writes", chown = "writes", tee = "writes",

  rm = "deletes", rmdir = "deletes", unlink = "deletes", shred = "deletes",

  -- suites
  pytest = "tests", jest = "tests", vitest = "tests", mocha = "tests",
  tox = "tests", nose = "tests", busted = "tests", rspec = "tests",

  -- building
  make = "builds", cmake = "builds", ninja = "builds", gcc = "builds",
  clang = "builds", rustc = "builds", tsc = "builds", webpack = "builds",
  vite = "builds", esbuild = "builds", luac = "builds", javac = "builds",

  -- dependencies
  pip = "installs", pip3 = "installs", brew = "installs", apt = "installs",
  ["apt-get"] = "installs", yum = "installs", pacman = "installs",
  gem = "installs", pixi = "installs", uv = "installs",

  -- the network
  curl = "connects", wget = "connects", ssh = "connects",
  scp = "connects", rsync = "connects", nc = "connects",
  ping = "connects", dig = "connects", telnet = "connects",

  -- another user
  sudo = "escalates", doas = "escalates", su = "escalates",
}

local BY_SUBCOMMAND = {
  git = {
    status = "inspects", log = "inspects", diff = "inspects", show = "inspects",
    branch = "inspects", blame = "inspects", ["ls-files"] = "inspects",
    add = "writes", checkout = "writes", restore = "writes", stash = "writes",
    clean = "deletes",
    commit = "commits",
    push = "publishes", tag = "publishes",
    clone = "connects", fetch = "connects", pull = "connects",
  },
  npm = {
    test = "tests", install = "installs", i = "installs", add = "installs", ci = "installs",
    uninstall = "installs", init = "writes", pkg = "writes",
    build = "builds", run = nil,   -- `npm run <script>` is named by the script
    publish = "publishes",
    exec = nil,                    -- `npm exec <program>`, like npx: named by the program
  },
  yarn = { test = "tests", install = "installs", build = "builds", publish = "publishes" },
  pnpm = { test = "tests", install = "installs", build = "builds", publish = "publishes" },
  cargo = {
    test = "tests", check = "inspects", clippy = "inspects", tree = "inspects",
    build = "builds", ["rustc"] = "builds",
    add = "installs", update = "installs", fetch = "connects",
    publish = "publishes",
  },
  go = { test = "tests", build = "builds", get = "installs", vet = "inspects" },
  docker = {
    ps = "inspects", images = "inspects", logs = "inspects",
    build = "builds", pull = "connects", push = "publishes", run = nil,
  },
  kubectl = { get = "inspects", describe = "inspects", logs = "inspects",
              apply = "publishes", delete = "deletes" },
  terraform = { plan = "inspects", apply = "publishes", destroy = "deletes" },
  systemctl = { status = "inspects", start = "publishes", stop = "publishes" },
}

-- A script the workspace holds, named by what it is called. This is the ONE place a name
-- is read rather than a program, and it is bounded: only the basename of an argv[0] that
-- is plainly a path into the workspace, and only against the same closed set. A script
-- called nothing this knows is a gap like any other.
local BY_SCRIPT_NAME = {
  test = "tests", tests = "tests", check = "tests", spec = "tests",
  build = "builds", compile = "builds", bundle = "builds",
  deploy = "publishes", release = "publishes", publish = "publishes",
  install = "installs", setup = "installs",
  lint = "inspects", fmt = "inspects", format = "inspects",
  clean = "deletes",
}

-- Shell plumbing: placed, and it is NOTHING. `cd` changes a directory, `echo` prints,
-- `true` succeeds. None of them is an act worth measuring, and counting them as gaps
-- would put a number on the report that says the vocabulary is missing something when it
-- is not. A gap and a nothing are different answers and this reader gives both.
local PLUMBING = {
  cd = true, echo = true, printf = true, ["true"] = true, ["false"] = true,
  [":"] = true, set = true, unset = true, export = true, source = true,
  ["."] = true, exit = true, ["return"] = true, shift = true, read = true,
  sleep = true, wait = true, exec = true, eval = true, alias = true,
}

-- An interpreter is a PREFIX, not the command: `lua run-tests.lua` runs run-tests.lua,
-- and `python manage.py migrate` runs manage.py. Structural, like the assignment prefix
-- and `env` above -- an interpreter's first non-option argument IS the command, in every
-- one of them, which is why this is a rule and not a table entry that could be missing.
--
-- `-c` and `-e` are the exception and stay a gap: a program passed on the command line
-- has no name, and this reader does not read the program.
local INTERPRETERS = {
  lua = true, luajit = true, python = true, python3 = true, node = true,
  ruby = true, perl = true, sh = true, bash = true, zsh = true, deno = true,
  bun = true, php = true, Rscript = true,
}

local function basename(path)
  return (path:match("([^/\\]+)$") or path)
end

local function script_term(head, bare)
  -- `./run-tests.sh`, `tools/cargo.sh`, `scripts/deploy` -- a path, not a program. Unless
  -- `bare`, which is what an interpreter's argument is: `lua run-tests.lua` names a file
  -- in this directory and there is nothing else it could be.
  if not bare and not head:find("[/\\]") and head:sub(1, 1) ~= "." then return nil end
  local name = basename(head):gsub("%.%w+$", "")
  for part in name:gmatch("[%a]+") do
    local term = BY_SCRIPT_NAME[part:lower()]
    if term then return term end
  end
  return nil
end

--- What one simple command did.
---
--- Three answers, and the difference between the last two is the design:
---
---   * a term         -- this command did that;
---   * `nil, "plain"` -- placed, and it is nothing an agent's behaviour turns on;
---   * `nil`          -- a GAP. Counted by `command.acts` and reported, never repaired by
---                       loosening anything here.
function command.act(simple)
  if type(simple) ~= "table" or type(simple.argv) ~= "table" then return nil end
  local argv = simple.argv
  local head = argv[1]
  if type(head) ~= "string" or head == "" then return nil end

  -- Structural, and it comes first: a line that redirects into a file WRITES, whatever
  -- ran. This is the grammar half answering, not the naming half -- `>` means the same
  -- thing after every program there has ever been, so no table can be missing an entry
  -- for it.
  for i = 1, #(simple.redirects or {}) do
    local op = simple.redirects[i].op
    if op == ">" or op == ">>" then return "writes" end
  end

  -- An assignment prefix (`FOO=bar cmd`) and an env wrapper are not the command.
  local at = 1
  while type(argv[at]) == "string" and argv[at]:match("^[%w_]+=") do at = at + 1 end
  head = argv[at]
  if type(head) ~= "string" or head == "" then return nil end
  if (head == "env" or head == "nice" or head == "time") and type(argv[at + 1]) == "string" then
    at = at + 1
    head = argv[at]
  end

  -- Running as another user is what this command IS, whatever it goes on to run: an
  -- agent that escalated is the fact somebody wants, and the thing it escalated to run
  -- is a second act this reader does not conflate with the first.
  local program = basename(head)

  -- Step through an interpreter to the script it runs, at most once: `sh -c "..."` is a
  -- shell inside a shell and this reader does not re-enter it.
  local interpreted = false
  if INTERPRETERS[program] then
    interpreted = true
    local k = at + 1
    while type(argv[k]) == "string" and argv[k]:sub(1, 1) == "-" do
      -- A program given on the command line has no name to read.
      if argv[k] == "-c" or argv[k] == "-e" then return nil end
      k = k + 1
    end
    if type(argv[k]) == "string" and argv[k] ~= "" then
      head = argv[k]
      at = k
      program = basename(head)
    else
      return nil
    end
  end

  if PLUMBING[program] then return nil, "plain" end
  if BY_PROGRAM[program] == "escalates" then return "escalates" end

  local subs = BY_SUBCOMMAND[program]
  if subs then
    -- The first argument that is not an option is the subcommand.
    local k = at + 1
    while type(argv[k]) == "string" and argv[k]:sub(1, 1) == "-" do k = k + 1 end
    local sub = argv[k]
    if type(sub) == "string" then
      local term = subs[sub]
      if term then return term end
      -- `npm run build`, `cargo run`, `docker run` -- named by what is run, not by `run`.
      if sub == "run" and type(argv[k + 1]) == "string" then
        local named = BY_SCRIPT_NAME[argv[k + 1]:lower()]
        if named then return named end
      end
      -- `npm exec vitest`, like `npx vitest` below: named by the program it runs.
      if sub == "exec" and program == "npm" and type(argv[k + 1]) == "string" then
        return BY_PROGRAM[argv[k + 1]]
      end
    end
    return nil
  end

  -- `npx vitest run`, `npx tsc --noEmit`: npx runs a package's program, and the line is
  -- named by that program, exactly as the program would be on its own. Found by the
  -- long-task eval, where every test and build the model ran went through npx.
  if program == "npx" then
    local k = at + 1
    while type(argv[k]) == "string" and argv[k]:sub(1, 1) == "-" do k = k + 1 end
    if type(argv[k]) == "string" then return BY_PROGRAM[argv[k]] end
    return nil
  end

  local direct = BY_PROGRAM[program]
  if direct then return direct end

  return script_term(head, interpreted)
end

--- Every act in one line, with what could not be placed.
---
--- `unplaced` is the number that goes on a report: a reader that answered a term for
--- everything would be a reader nobody could check.
function command.acts(line)
  local parsed, why, where = command.parse(line)
  if not parsed then
    return { acts = {}, unplaced = 1, commands = 1, why = why, where = where }
  end
  local acts, seen, unplaced = {}, {}, 0
  for i = 1, #parsed do
    local term, plain = command.act(parsed[i])
    if term == nil then
      -- Plumbing is placed and is nothing. Counting it as a gap would put a number on the
      -- report saying the vocabulary is missing something when it is not.
      if plain ~= "plain" then unplaced = unplaced + 1 end
    elseif not seen[term] then
      seen[term] = true
      acts[#acts + 1] = term
    end
  end
  -- Sorted, so the same line reads the same twice and two runs can be compared.
  table.sort(acts)
  return { acts = acts, unplaced = unplaced, commands = #parsed }
end

return command
