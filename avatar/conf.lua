-- Soft cat mark. A host of its own: the console's 16-colour grid cannot
-- hold this, so the mark lives here and is opened with `love avatar`.
function love.conf(t)
  t.identity = "malleable-avatar"
  t.version = "11.5"
  t.console = false

  t.window.title = "avatar"
  t.window.width = 800
  t.window.height = 800
  t.window.minwidth = 240
  t.window.minheight = 240
  t.window.resizable = true
  t.window.vsync = 1
  t.window.highdpi = true

  t.modules.audio = false
  t.modules.sound = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
end
