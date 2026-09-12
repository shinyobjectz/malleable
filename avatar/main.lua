-- Soft cat mark. Drawn, not stamped: a signed-distance cat head, a Gaussian
-- edge, and a chromatic fringe on the lower-right — the same construction as
-- the reference (a melted silhouette, two white eyes, a cyan/magenta rim).
--
--     love avatar              watch it
--     love avatar --capture    write avatar/preview.png and quit

local SRC = love.filesystem.getSource()

local CAPTURE = false
for i = 1, #arg do
  if arg[i] == "--capture" then CAPTURE = true end
end

-- The mark is authored in a square. The shader sees uv in that square,
-- origin at the centre, +y up, the head filling the middle third.
local SHADER = [[
float sdEllipse(vec2 p, vec2 r) {
  vec2 q = p / r;
  return (length(q) - 1.0) * min(r.x, r.y);
}

float smin(float a, float b, float k) {
  float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

// Polynomial erf approximation, good enough for a coverage integral.
float erf_approx(float x) {
  float s = sign(x);
  x = abs(x);
  float t = 1.0 / (1.0 + 0.3275911 * x);
  float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
                    - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
  return s * y;
}

// Coverage of a blurred half-plane: 1 inside, 0 outside.
float cover(float d, float sigma) {
  return 0.5 - 0.5 * erf_approx(d / (sigma * 1.41421356));
}

float cat(vec2 p) {
  // Round head. Ears are rotated ellipses — pointed enough to read as
  // ears, blunt enough that the blur cannot turn them into needles.
  float head = sdEllipse(p - vec2(0.0, -0.08), vec2(0.305, 0.280));

  vec2 qL = p - vec2(-0.155, 0.095);
  vec2 rL = vec2( 0.82 * qL.x + 0.57 * qL.y, -0.57 * qL.x + 0.82 * qL.y);
  float earL = sdEllipse(rL, vec2(0.095, 0.155));

  vec2 qR = p - vec2( 0.120, 0.090);
  vec2 rR = vec2( 0.97 * qR.x - 0.24 * qR.y,  0.24 * qR.x + 0.97 * qR.y);
  float earR = sdEllipse(rR, vec2(0.100, 0.145));

  float d = smin(head, earL, 0.075);
  d = smin(d, earR, 0.070);
  return d;
}

float eye(vec2 p, vec2 c, float r, float sigma) {
  return cover(length(p - c) - r, sigma);
}

vec4 effect(vec4 colour, Image tex, vec2 uv, vec2 pix) {
  vec2 res = love_ScreenSize.xy;
  float side = min(res.x, res.y);
  vec2 p = (pix - 0.5 * res) / side;
  p.y = -p.y;
  // Scale so the melted head fills the same fraction of the frame as the reference.
  p *= 1.32;

  float sigma = 0.060;
  float d = cat(p);
  float a = cover(d, sigma);
  vec3 col = vec3(1.0 - a);

  // Tight crescent on the lower-right rim only. Cyan on the outside,
  // magenta as it slips under — a sliver, not a cheek.
  float ang = atan(p.y, p.x);
  float rim = exp(-pow((ang + 0.72) / 0.38, 2.0));
  float edge = smoothstep(0.12, 0.42, a) * smoothstep(0.78, 0.48, a);
  vec3 magenta = vec3(0.82, 0.28, 0.96);
  vec3 cyan = vec3(0.35, 0.82, 1.0);
  float split = clamp((ang + 0.95) / 0.55, 0.0, 1.0);
  vec3 irid = mix(magenta, cyan, split);
  col = mix(col, irid, clamp(edge * rim * 1.15, 0.0, 0.85));

  // Eyes sit in the lower half, left one a touch lower, both a little
  // softer than a hard disc so they bloom the way the reference does.
  float eL = eye(p, vec2(-0.122, -0.100), 0.046, 0.008);
  float eR = eye(p, vec2( 0.140, -0.062), 0.046, 0.008);
  float eyes = clamp(eL + eR, 0.0, 1.0);
  col = mix(col, vec3(1.0), eyes);

  return vec4(col, 1.0);
}
]]

local shader

local function write_png(image_data, path)
  local bytes = image_data:encode("png"):getString()
  local f, why = io.open(path, "wb")
  if not f then error(why) end
  f:write(bytes)
  f:close()
end

local function render_to(w, h)
  local canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
  love.graphics.setCanvas(canvas)
  love.graphics.clear(1, 1, 1, 1)
  love.graphics.setShader(shader)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setShader()
  love.graphics.setCanvas()
  return canvas
end

function love.load()
  love.graphics.setDefaultFilter("linear", "linear", 8)
  shader = love.graphics.newShader(SHADER)
  if CAPTURE then
    local canvas = render_to(800, 800)
    write_png(canvas:newImageData(), SRC .. "/preview.png")
    love.event.quit()
  end
end

function love.draw()
  if not shader then return end
  love.graphics.clear(1, 1, 1, 1)
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
  love.graphics.setShader()
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  elseif key == "s" then
    local canvas = love.graphics.newCanvas(800, 800, { dpiscale = 1 })
    love.graphics.setCanvas(canvas)
    love.graphics.clear(1, 1, 1, 1)
    love.graphics.setShader(shader)
    love.graphics.rectangle("fill", 0, 0, 800, 800)
    love.graphics.setShader()
    love.graphics.setCanvas()
    write_png(canvas:newImageData(), SRC .. "/preview.png")
  end
end
