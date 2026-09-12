# home — the console's home screen: a stage and a bar

`console/lib/home.lua` and `console/lib/bar.lua`, drawn by `console/main.lua` (`love
console`, or the shipped `build/malleable.love`; `scripts/ship.sh`). Written 2026-09-11, after the character and the history grid
before it were taken out: both put a design between the person and the one thing the
screen is for, which is what the agent makes.

## What it is

The window is two parts:

- **the stage**, everything above the bar, a plain dark ground a shade above the bar's, read in light ink (ruled 2026-09-11: a dark reader, never a light page). It is for the agent's
  file (docs/agent-file-plan.md; its contract is docs/spec/agent-file.md once written).
  Until that is drawn it shows the transcript (Tab), in ink, with a margin, and nothing
  else: no status and no chrome, and nothing along the top.
- **the bar**, one strip along the foot, under a tenth of the window's height. It is all
  the agent shows of itself.

## The bar

It is a grid of dots, and it has three states. Nothing else about it changes: its height
stays the same, and one state fades into the next in a fifth of a second.

| state | when | the dots |
| --- | --- | --- |
| quiet | nothing is being said | dark |
| hearing | the microphone is open, or a line is being typed | grey and white |
| speaking | the voice is saying a reply, or with no voice, for as long as reading the reply takes | in colour, their hues moving along the bar |

In both lit states each dot's size and light is a field. The speaker's level is poured in
a few places at a time, and each key typed goes in just past the end of the line. The
field spreads to the neighbouring dots and fades, stepped sixty times a second. The
person's level is the microphone's. The agent's level is measured from what the speaker is
playing; with no voice it is a pulse at the pace of speech. Thinking and working are quiet.

**No dot under text moves.** Under the caption, the line being typed and the hints, the
dots rest at a sixth of their light. The light is poured only into the columns on either
side, so while there is a caption the light moves at the two ends of the bar.

The **caption** is in the middle of the bar, one line of it, at most three fifths of the
bar's width. While the person is still speaking it is the last line of what has been
heard. Otherwise the lines come in turn at the pace they are read (fifteen characters a
second), and the last one fades six seconds after it has been read. C turns captions off
and on. They are not shown while the transcript is open.

The **line being typed** takes the caption's place in the middle, with its caret. With
nothing typed, the middle says "Type to the agent. Enter sends, Esc closes." while there is
no caption.

The **hints** are at the ends of the bar: each action's key and a word for it, small, three
at the left end (Space talk, T type, Tab transcript) and three at the right (C captions,
M voice, Esc stop). They fade in while the pointer is over the bar or just above it, and
out when it leaves. While they show, the caption fades. A click on a hint does its action.
A window too narrow for the words shows the keys alone. The hints do not show while a line
is being typed. All text on the bar is light.

## The view

`h:view(w, hgt, measure)` answers `{ stage, bar, items, size }`. `stage` and `bar` are
rectangles, `stage` from the top of the window down to `bar`, and `bar` across the whole
width at the foot. `items` are drawn in order, each one a `rect`, a `circle` (with
`segments`) or a `text`, with `rgb` and `alpha`. Every place is worked out from `w` and `hgt` alone, on every
frame, so a window of any size is laid out correctly on its first frame at that size.

`h:pointer(x, y)` says where the pointer is, and `h:pointer(nil)` that it has left the
window. `h:hear_level(x)` and `h:say_level(x)` give the loudness, 0 to 1, of the
microphone and of what the speaker is playing now. `h:hit(x, y)` answers the action under a point, and `h:press(x, y)` does it.

## Resizing

The window can be made as small as 320 by 240. On macOS, LÖVE 11.5 draws no frames while
an edge of the window is being dragged: the system holds the program's loop until the
mouse is let go (measured 2026-09-11: a test window drew nothing across a two-second
drag, then its first frame at the new size). The screen is laid out again on that frame;
nothing moves into place afterwards. Drawing during the drag would need the host to draw
from inside the resize event, which LÖVE 11 does not offer from Lua.

## Open

- Both levels are peaks with a gain: the microphone's (times two) sits at 1 through most
  speech, so the dots bloom the same for a whisper and a shout. A level from the signal's
  energy would let them follow the voice.
- A job waiting on the person is said by the talker and put in the transcript; the bar
  does not show it.
- How the transcript gives way to the agent's file on the stage.
