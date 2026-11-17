# NH4X REAPER Tools

Free scripts for REAPER by NH4X. Music: https://nh4x.bandcamp.com/

| Tool | What it does | Version |
|---|---|---|
| [NH4X Envelope shaper](#nh4x-envelope-shaper) | Panel with drag strips to reshape envelope points: stretch, tilt, scale, warp, rotate, generate | 1.0 |

## Contents
1. [Install](#install)
2. [NH4X Envelope shaper](#nh4x-envelope-shaper)
3. [Known limits](#known-limits)
4. [Changes](#changes)
5. [License](#license)

## Install
Do these steps in order, once.

### Step 1 · Install ReaPack
ReaPack is the free package manager for REAPER. Already have it? Go to step 2.

1. Go to https://reapack.com/ and download ReaPack for your system (Windows: `reaper_reapack-x64.dll`).
2. In REAPER: **Options > Show REAPER resource path in explorer/finder**. Open the folder **UserPlugins** (create it if it's missing) and copy the file in there.
3. **Close REAPER and start it again.** ReaPack opens its *Manage repositories* window once: that means it works.

### Step 2 · Install ReaImGui
The Envelope shaper's panel is built with **ReaImGui**. ReaPack doesn't install it for you, so do it first:

1. **Extensions > ReaPack > Browse packages**.
2. Type **ReaImGui** into the filter.
3. Right-click **ReaImGui: ReaScript binding for Dear ImGui** > **Install**, then **Apply**.
4. **Restart REAPER.**

(ReaImGui comes from the *ReaTeam Extensions* repository that ReaPack has by default.)

### Step 3 · Add this repository
1. **Extensions > ReaPack > Import repositories...**
2. Paste this line and click **OK**:

```
https://github.com/NH4Xnet/reaper-tools/raw/main/index.xml
```

### Step 4 · Install the tools
1. **Extensions > ReaPack > Browse packages**.
2. Type **NH4X** into the filter.
3. Right-click **NH4X Envelope shaper** > **Install**, then **Apply**.

The script now sits in the action list as **Script: NH4X Envelope shaper.lua**.

## NH4X Envelope shaper
A panel with drag strips that reshape envelope points while you watch. Drag a strip left or right: the envelope changes live. Let go = one undo step.

### Start it
- **Actions > Show action list**, search **NH4X Envelope**, **Run**.
- It's a **toggle action**: run it again and the panel closes. On a toolbar button or a controller pad, the button lights up while the panel is open.
- Tip: right-click a toolbar > **Customize toolbar...** > **Add...** and pick the script, or give it a shortcut in the action list.

### What it edits (TARGET)
Click an envelope lane first. The **TARGET** line at the top tells you what will be edited:

1. **Razor area** on the selected envelope: everything inside it. The edges are kept, so the rest of the lane doesn't jump.
2. Else the **selected points** on the selected envelope.
3. Else a **selected automation item**: the whole item.

Works on track envelopes, take envelopes and automation items. Pooled automation items: the TARGET line warns you that all copies change.

### Using the strips
- **Drag** left / right = less / more. The amount shows on the right of the strip.
- **Shift** while dragging = fine, and in between the round values.
- **Esc** while dragging = cancel, everything goes back.
- Strips land on round values (5 % steps, whole dB). Hold Shift for the values in between.
- Rest the mouse on a control for a short tip.

### TIME
- **STRETCH** with switch **L / R**: squeeze or expand in time. L = the left edge moves, R = the right edge moves.
- **MOVE**: shift all target points in time.
- **WARP**: bunch the points towards the start or the end. The edges stay.
- **ROTATE**: slide the pattern inside the area in steps of its own points. What falls off one end comes back at the other.
- **Snap time to grid**: STRETCH and MOVE snap to the project grid.

### SHAPE (the line between the points)
- **BEND**: curve the lines between the points (Bezier). Left = bend down, right = bend up.
- **LINEAR, SQUARE, SLOW S/E, FAST START, FAST END, BEZIER**: one click sets that point shape for the whole target.

### VALUE
- **TILT** with switch **L / R**: lift or lower one side, the other side stays. The menu below picks the tilt curve (Linear, Slow start, Slow end, S-curve), **Steepness** sets how strong the curve is.
- **SCALE** with switch **LOW / MID / HIGH**: make the movement smaller or bigger. LOW = the lowest point stays, MID = the middle stays (compress / expand), HIGH = the highest point stays.
- **MOVE**: shift all values up or down.
- **WARP**: bend the values towards the low or high end. Lowest and highest point stay.
- **JITTER**: random variation per point. Every drag rolls a new pattern.

### ONE CLICK
- **FLIP VALUES**: upside down (highest becomes lowest).
- **REVERSE**: backwards in time. The curves are reversed too.
- **UNDO / REDO**: REAPER's undo, so you don't have to leave the panel.

### POINTS
- **ADD POINTS**: fill the target with evenly spaced points that sit exactly on the current line, so nothing changes until you shape them. The menu next to it sets the spacing: every grid step, 1/4, 1/8, 1/16 or 1/32.
- **REDUCE**: remove the points the line doesn't need (after freehand drawing or a recorded knob). Curved points stay.
- **DESELECT**: unselect all envelope points on this track, automation items included.

### GENERATE
Replaces the target with a shape.
1. Pick the shape: Ramp up, Ramp down, Swell, Fade, Sine, Triangle, Saw up, Saw down, Square, Random steps, Random smooth.
2. **Cycles**: how many times the shape repeats inside the target. The random shapes use the POINTS spacing instead.
3. **Low / High**: the range of the shape. Shown in dB on volume lanes, in the plugin's own units on FX parameter lanes (e.g. Hz on a filter), else in %.
4. Click **GENERATE**.

### VOLUME LANES
Sets the top of volume lanes: **0 dB** or **+6 dB** (default). With 0 dB nothing goes above 0 dB: the strips stop there, and a point above 0 dB comes down to 0 dB as soon as a strip moves it. Grayed out when the selected lane isn't a volume lane.

## Known limits
- One envelope lane at a time.
- The tempo map and MIDI CC lanes are not supported.
- Looped automation items are refused: turn Loop off, or trim the item to one pass.
- Needs ReaImGui 0.10 or newer.

## Changes
- **1.0** · first public release of the NH4X Envelope shaper.

## License
**CC BY-NC-SA 4.0** (Creative Commons Attribution-NonCommercial-ShareAlike 4.0): https://creativecommons.org/licenses/by-nc-sa/4.0/

- **Free** to use, share and change, as long as it's not commercial.
- **Credit** NH4X and link to this repository.
- **Changed versions** you share must use the same license.
- **Your music is yours.** The license only covers the code.
- **Commercial use of the code** (selling it, bundling it in a paid product) needs a separate license from me. Open an issue on this repository and we'll talk.
