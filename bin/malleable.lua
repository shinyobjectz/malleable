-- The only file in the tree that touches the real world: build it, run, exit.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path
local cli = require "cli"
os.exit(cli.main(arg, {
  out  = function (text) io.stdout:write(text) end,
  err  = function (text) io.stderr:write(text) end,
  read = function (path)
    local f, why = io.open(path, "rb")
    if not f then
      return nil, (tostring(why):find("No such file") and "missing" or tostring(why))
    end
    local text = f:read("*a")
    f:close()
    return text
  end,
  stdin = function () return io.read("*a") end,
  env   = os.getenv,
  now   = os.time,
}), true)
