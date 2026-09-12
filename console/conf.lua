-- The window the LÖVE host opens: an ordinary one, resizable down to 320 by 240, and none
-- of the modules the console has no use for (sound is the ML engine's own, not LÖVE's).
function love.conf(t)
  t.identity = "malleable"
  t.version = "11.5"
  t.console = false

  t.window.title = "malleable"
  t.window.width = 560
  t.window.height = 665
  t.window.minwidth = 320
  t.window.minheight = 240
  t.window.resizable = true
  t.window.borderless = false
  t.window.vsync = 1
  t.window.highdpi = true
  t.window.msaa = 4

  t.modules.audio = false
  t.modules.sound = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
end
