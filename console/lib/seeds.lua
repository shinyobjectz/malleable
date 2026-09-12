-- seeds — the agents and kits the console puts in a workspace, and how it loads them.
--
--     local seeds = require "console.lib.seeds"
--     local agent, path, workers, notes = seeds.load(o, dir, fs)
--
-- `o.agent` names the file on the stage, or the notebook in the workspace's agents/ folder;
-- `fs` is { read, write, mkdir, seed }: the host's files, and `seed(rel)` a file of the
-- tree (console/agents/x.feature, library/modes.lua) from the archive or the checkout.
-- The first time a workspace is opened, the shipped agents and the kits they use are put
-- in agents/; a file already there is the person's and is never overwritten
-- (docs/spec/home.md, "The agents in the workspace"). Nothing here names `love`.

local seeds = {}

seeds.AGENTS  = { "notebook", "author", "reader" }           -- put in the workspace the first time
seeds.KITS    = { ["modes.lua"] = "library/modes.lua" }      -- the kits the seeded agents use (docs/spec/modes.md)
seeds.WORKERS = { "notebook", "author" }                     -- the talker's own; the reader is the notebook's delegate

function seeds.load(o, dir, fs)
  local agent = require "agent"
  local declare, spec = require "declare", require "spec"
  local folder = dir .. "/agents"
  local notes = {}
  for _, name in ipairs(seeds.AGENTS) do
    local path = folder .. "/" .. name .. ".feature"
    if not fs.read(path) then
      local seed = fs.seed("console/agents/" .. name .. ".feature")
      if seed then fs.mkdir(folder); fs.write(path, seed) end
    end
  end
  for name, source in pairs(seeds.KITS) do
    local path = folder .. "/" .. name
    if not fs.read(path) then
      local seed = fs.seed(source)
      if seed then fs.mkdir(folder); fs.write(path, seed) end
    end
  end
  local path = o.agent or (folder .. "/notebook.feature")
  local text = fs.read(path)
  if not text then return nil, "no agent at " .. path end
  local from = path:match("^(.*)[/\\][^/\\]*$") or "."
  local function read(p)
    local t = fs.read(from .. "/" .. p)
    if not t then return nil, "no such file" end
    return t
  end
  local ok, why
  if path:match("%.feature$") then ok, why = pcall(agent.declare, text, { read = read })
  else ok, why = pcall(fs.run, path) end
  if not ok then return nil, tostring(why) end
  local main = agent.spec()
  local workers = { [main.name] = main }
  for _, name in ipairs(seeds.WORKERS) do
    local other = fs.read(folder .. "/" .. name .. ".feature")
    if other and folder .. "/" .. name .. ".feature" ~= path then
      local s = spec.new()
      local info, bad = declare.apply(other, s, { read = read })
      if info and s.name and not workers[s.name] then workers[s.name] = s
      else notes[#notes + 1] = name .. ".feature is left out: " .. tostring(bad or "it declares no name") end
    end
  end
  return agent, path, workers, notes
end

return seeds
