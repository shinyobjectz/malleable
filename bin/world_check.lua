-- The disk half of the hostile suite: `lua bin/world_check.lua`. A host file, because it
-- needs a real disk, which no test under test/ may touch.
--
-- It builds a throwaway root with a folder beside it, then aims every escape at that
-- folder through bin/world.lua's disk port: `../`, absolute paths, a link to a directory
-- outside, a link to a file outside, and a link that points nowhere yet. Each must be
-- refused, the outside folder must be exactly as it was, and an ordinary write inside the
-- root must still work. Exits non-zero on the first thing that got through.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../src/?.lua;" .. package.path

local world = require "world"

local function sh(cmd)
  local r = os.execute(cmd)
  assert(r == true or r == 0, "setup failed: " .. cmd)
end

local base = os.tmpname()
os.remove(base)
local root, outside = base .. "/root", base .. "/outside"
sh("mkdir -p '" .. root .. "/ok' '" .. outside .. "'")
sh("printf secret > '" .. outside .. "/secret.txt'")
sh("ln -s '" .. outside .. "' '" .. root .. "/out'")
sh("ln -s '" .. outside .. "/secret.txt' '" .. root .. "/link.txt'")
sh("ln -s '" .. outside .. "/planted.txt' '" .. root .. "/dangling'")

local fs = world.fs(root)
local failures = 0
local function expect(label, ok)
  io.write((ok and "ok    " or "FAIL  ") .. label .. "\n")
  if not ok then failures = failures + 1 end
end

local function refused(v, err) return v == nil and type(err) == "table" and err.code == "denied" end

expect("write ../ is refused",               refused(fs.write("../outside/x.txt", "x")))
expect("write an absolute path is refused",  refused(fs.write(outside .. "/x.txt", "x")))
expect("write through a directory link",     refused(fs.write("out/x.txt", "x")))
expect("write through a file link",          refused(fs.write("link.txt", "x")))
expect("read through a file link",           refused(fs.read("link.txt")))
expect("read through a directory link",      refused(fs.read("out/secret.txt")))
expect("list through a directory link",      refused(fs.list("out")))
expect("remove through a file link",         refused(fs.remove("link.txt")))
expect("write through a dangling link",      refused(fs.write("dangling", "x")))
expect("exists says no through a link",     fs.exists("out/secret.txt") == false)
expect("an ordinary write still works",      fs.write("ok/fine.txt", "fine") == true)
expect("and reads back",                     fs.read("ok/fine.txt") == "fine")
expect("a new nested folder still works",    fs.write("new/deep/file.txt", "x") == true)

local f = io.open(outside .. "/secret.txt", "rb")
local secret = f and f:read("*a")
if f then f:close() end
expect("the outside file is untouched", secret == "secret")
local p = io.popen("ls -A '" .. outside .. "'")
local names = p:read("*a")
p:close()
expect("nothing new appeared outside", names == "secret.txt\n")

-- The history port (docs/spec/history.md): where a workspace sits in git, read from the
-- files git keeps; a claim two processes cannot both win; the key never written.
local history = require "history"
local key = "sk-or-v1-0123456789abcdef"
local function git(dir, head, refs)
  sh("mkdir -p '" .. dir .. "/.git/refs/heads/feature'")
  sh("printf '" .. head .. "\\n' > '" .. dir .. "/.git/HEAD'")
  for ref, sha in pairs(refs or {}) do sh("printf '" .. sha .. "\\n' > '" .. dir .. "/.git/" .. ref .. "'") end
end

local plain = base .. "/plain"
sh("mkdir -p '" .. plain .. "'")
local w = world.history(plain, { key }).where()
expect("no git: the worktree alone", w.worktree == "plain" and w.git_branch == nil)
expect("no git: the id's first part is the worktree", history.id(w, 0, "a", "cli"):match("^plain/") ~= nil)

local repo = base .. "/notes"
git(repo, "ref: refs/heads/feature/voice", { ["refs/heads/feature/voice"] = "0123456789abcdef0123456789abcdef01234567" })
sh("mkdir -p '" .. repo .. "/sub'")
w = world.history(repo .. "/sub", { key }).where()
expect("a git branch, found from a folder inside the repository", w.git_branch == "feature/voice" and w.commit == "0123456")
expect("the id writes its / as ~", history.id(w, 0, "a", "cli"):match("^sub@feature~voice/") ~= nil)
expect("the offset is a number of seconds", type(w.offset) == "number" and w.offset % 60 == 0)

local packed = base .. "/packed"
git(packed, "ref: refs/heads/main")
sh("printf '# pack-refs\\nfedcba9876543210fedcba9876543210fedcba98 refs/heads/main\\n' > '" .. packed .. "/.git/packed-refs'")
w = world.history(packed, {}).where()
expect("a commit from packed-refs", w.git_branch == "main" and w.commit == "fedcba9")

local detached = base .. "/detached"
git(detached, "abcdef0123456789abcdef0123456789abcdef01")
w = world.history(detached, {}).where()
expect("a detached head is its commit", w.git_branch == "abcdef0" and w.commit == "abcdef0")

local worktree = base .. "/tree"
sh("mkdir -p '" .. worktree .. "' '" .. repo .. "/.git/worktrees/tree'")
sh("printf 'gitdir: " .. repo .. "/.git/worktrees/tree\\n' > '" .. worktree .. "/.git'")
sh("printf 'ref: refs/heads/main\\n' > '" .. repo .. "/.git/worktrees/tree/HEAD'")
sh("printf '../..\\n' > '" .. repo .. "/.git/worktrees/tree/commondir'")
sh("printf '1111111222222233333334444444555555566666\\n' > '" .. repo .. "/.git/refs/heads/main'")
w = world.history(worktree, {}).where()
expect("a git worktree's branch and commit", w.worktree == "tree" and w.git_branch == "main" and w.commit == "1111111")

local hp = world.history(plain, { key })
local id = "plain/2026-09-11/12-00-00-a-cli"
expect("a claim is won once", hp.claim(id) == true and hp.claim(id) == false)
expect("a claimed run is listed", (hp.list("runs/plain/2026-09-11") or {})[1] == "12-00-00-a-cli")
expect("a write and a read", hp.write("runs/" .. id .. "/story", "Scenario: one\n") == true
  and hp.read("runs/" .. id .. "/story") == "Scenario: one\n")
hp.write("index", "the key is " .. key .. "\n")
hp.append("index", "again " .. key .. "\n")
expect("the key is never written", hp.read("index") == "the key is [key]\nagain [key]\n")
expect("no half-written file is left", not (hp.list("") or {})[3] and (hp.list("") or {})[1] == "index")
expect("a path out of the history is refused", hp.write("../escape", "x") == nil and hp.read("/etc/hosts") == nil)
expect("it lives under the workspace", io.open(plain .. "/.malleable/history/index") ~= nil)

sh("rm -rf '" .. base .. "'")
io.write(failures == 0 and "\nthe disk port held\n" or ("\n" .. failures .. " escape(s) got through\n"))
os.exit(failures == 0 and 0 or 1)
