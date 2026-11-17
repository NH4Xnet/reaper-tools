-- @description NH4X Envelope shaper
-- @author NH4X
-- @version 1.1
-- @about
--   Panel with drag strips to reshape envelope points and MIDI editor lanes while you watch: stretch, move,
--   warp, rotate (time), tilt, scale, move, warp, jitter (value), bend + point shapes, add / reduce points, generate.
--   Envelopes: razor area on the selected envelope, else its selected points, else a selected automation item.
--   MIDI editor: last clicked CC / pitch bend / channel pressure / velocity lane; selected events, else the time selection.
--   Drag a strip left/right = live preview, release = one undo step, Esc = cancel, Shift = fine.
--   Toggle action: run again = close. Needs ReaImGui 0.10+ (install it via ReaPack first).
--   Manual: https://github.com/NH4Xnet/reaper-tools
--   Music: https://nh4x.bandcamp.com/

local SCRIPT  = 'NH4X Envelope shaper'
local VERSION = '1.1'

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB('This script needs ReaImGui.\n\nExtensions > ReaPack > Browse packages >\n"ReaImGui: ReaScript binding for Dear ImGui"', SCRIPT, 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local ctx = ImGui.CreateContext(SCRIPT)

---------------------------------------------------------------- settings
local EXT = 'NH4X_EnvShaper'
local cfg = {
  snap = false, curve = 0, steep = 2.0, spacing = 0,
  stretch_side = 1, tilt_side = 1, scale_anchor = 0,      -- switches: 0 = L / LOW, 1 = R / MID, 2 = HIGH
  gen = 4, cycles = 4, lo = 20, hi = 80,                  -- GENERATE: shape, cycles, low/high in % of lane
  vol_max = 1,                                            -- top of volume lanes: 0 = 0 dB, 1 = +6 dB
}
local NUM_KEYS = { 'curve', 'steep', 'spacing', 'stretch_side', 'tilt_side', 'scale_anchor', 'gen', 'cycles', 'lo', 'hi', 'vol_max' }

local function load_cfg()
  local s = reaper.GetExtState(EXT, 'snap')
  if s ~= '' then cfg.snap = (s == '1') end
  for _, k in ipairs(NUM_KEYS) do
    local v = tonumber(reaper.GetExtState(EXT, k))
    if v then cfg[k] = (k == 'steep' or k == 'lo' or k == 'hi') and v or math.floor(v) end
  end
end
local function save_cfg()
  reaper.SetExtState(EXT, 'snap', cfg.snap and '1' or '0', true)
  for _, k in ipairs(NUM_KEYS) do reaper.SetExtState(EXT, k, tostring(cfg[k]), true) end
end

-- ADD POINTS spacing: 0 = project grid, else quarter notes per step
local SPACING_QN = { 1, 0.5, 0.25, 0.125 }

-- off = project time of the envelope's time 0 (take envelopes: item position; track lanes: 0)
-- gridqn = MIDI editor grid in quarter notes (MIDI lanes), else the project grid
local function grid_times(t0, t1, off, gridqn)
  off = off or 0
  local qn = SPACING_QN[cfg.spacing] or gridqn
  if not qn then
    local _, div = reaper.GetSetProjectGrid(0, false)
    qn = div * 4
  end
  if not qn or qn <= 0 then qn = 0.25 end
  local out = {}
  local q = math.floor(reaper.TimeMap2_timeToQN(0, t0 + off) / qn + 1e-9) * qn + qn
  while #out < 4096 do
    local t = reaper.TimeMap2_QNToTime(0, q) - off
    if t >= t1 - 1e-4 then break end
    if t > t0 + 1e-4 then out[#out + 1] = t end
    q = q + qn
  end
  return out
end
load_cfg()

---------------------------------------------------------------- helpers
local EPS   = 1e-7
local GUARD = 0.001     -- guard points outside a razor area (s)
local PAD   = 0.0021    -- rewrite window padding (s)

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

-- copy of a point (MIDI points also carry their event ref, channel and mute flag)
local function cp(p) return { t = p.t, v = p.v, s = p.s, ten = p.ten, sel = p.sel, ref = p.ref, ch = p.ch, mu = p.mu } end

local function curve(x)
  x = clamp(x, 0, 1)
  local s = cfg.steep
  if cfg.curve == 1 then return x ^ s                       -- slow start
  elseif cfg.curve == 2 then return 1 - (1 - x) ^ s         -- slow end
  elseif cfg.curve == 3 then                                -- S-curve
    local a, b = x ^ s, (1 - x) ^ s
    return a / (a + b)
  end
  return x                                                  -- linear
end

---------------------------------------------------------------- envelope info
local function env_guid(env)
  local ok, g = reaper.GetSetEnvelopeInfo_String(env, 'GUID', '', false)
  if ok and g ~= '' then return g end
  local _, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  return chunk:match('EGUID%s+(%b{})') or ''
end

local function env_info(env)
  local _, name = reaper.GetEnvelopeName(env)
  local E = { env = env, name = name, mode = reaper.GetEnvelopeScalingMode(env), dmin = 0, dmax = 1 }
  local tr, fxi, pari = reaper.Envelope_GetParentTrack(env)
  local take
  if not tr then take, fxi, pari = reaper.Envelope_GetParentTake(env) end
  E.track, E.take = tr, take
  E.toff = 0   -- take envelope times start at the item: offset to project time for grid work
  if take then
    local item = reaper.GetMediaItemTake_Item(take)
    if item then E.toff = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') end
  end
  local lname = name:lower()
  if tr and fxi and fxi >= 0 then
    local _, mn, mx = reaper.TrackFX_GetParam(tr, fxi, pari); E.dmin, E.dmax = mn, mx
  elseif take and fxi and fxi >= 0 then
    local _, mn, mx = reaper.TakeFX_GetParam(take, fxi, pari); E.dmin, E.dmax = mn, mx
  elseif lname:find('volume') then
    -- volume works in the lane's own raw values (fader scaling = what you see), so equal moves look
    -- equal on screen; 0 = -inf, top = raw value of 0 dB or +6 dB (VOLUME LANES switch)
    E.lin = true
    E.dmin, E.dmax = 0, reaper.ScaleToEnvelopeMode(E.mode, cfg.vol_max == 0 and 1 or 2)
  elseif lname:find('pan') or lname:find('width') then
    E.dmin, E.dmax = -1, 1
  end
  return E
end

local function to_n(E, raw)
  local d = E.lin and raw or reaper.ScaleFromEnvelopeMode(E.mode, raw)
  local r = E.dmax - E.dmin
  if r < 1e-12 then return 0 end
  return (d - E.dmin) / r
end
local function from_n(E, n)
  n = clamp(n, 0, 1)
  local d = E.dmin + n * (E.dmax - E.dmin)
  if E.lin then return d end
  return reaper.ScaleToEnvelopeMode(E.mode, d)
end

local function find_razor(env, tr)
  if not tr then return end
  local guid = env_guid(env)
  if guid == '' then return end
  local _, rz = reaper.GetSetMediaTrackInfo_String(tr, 'P_RAZOREDITS', '', false)
  for a, b, g in rz:gmatch('(%S+) (%S+) "([^"]*)"') do
    if g == guid then return tonumber(a), tonumber(b), guid end
  end
end

---------------------------------------------------------------- automation items
local function ai_info(env, i)
  local function g(k) return reaper.GetSetAutomationItemInfo(env, i, k, 0, false) end
  local A = { idx = i, pos = g('D_POSITION'), len = g('D_LENGTH'), loop = g('D_LOOPSRC'),
              pool = g('D_POOL_ID'), sel = g('D_UISEL'), qnlen = g('D_POOL_QNLEN'), rate = g('D_PLAYRATE') }
  -- length of one loop pass in seconds (pool length is in quarter notes)
  local rate = (A.rate and A.rate > 0) and A.rate or 1
  local q0 = reaper.TimeMap2_timeToQN(0, A.pos)
  A.looplen = reaper.TimeMap2_QNToTime(0, q0 + A.qnlen / rate) - A.pos
  A.looped = A.loop > 0 and A.len > A.looplen + 0.001
  local n = 0
  for k = 0, reaper.CountAutomationItems(env) - 1 do
    if reaper.GetSetAutomationItemInfo(env, k, 'D_POOL_ID', 0, false) == A.pool then n = n + 1 end
  end
  A.pooled = n
  return A
end

-- what will be edited: razor > selected points (lane, then items) > selected automation item
local function resolve(env, tr)
  local nai = reaper.CountAutomationItems(env)
  local function check(T)
    if T.A and T.A.looped then
      return nil, 'Automation item ' .. (T.A.idx + 1) .. ' is looped: turn Loop off or trim it to one pass.'
    end
    return T
  end
  local r0, r1, guid = find_razor(env, tr)
  if r0 then
    local mid = (r0 + r1) / 2
    for i = 0, nai - 1 do
      local A = ai_info(env, i)
      if mid >= A.pos and mid <= A.pos + A.len then
        return check({ ai = i, A = A, mode = 'razor', guid = guid,
                       r0 = math.max(r0, A.pos), r1 = math.min(r1, A.pos + A.len) })
      end
    end
    return { ai = -1, mode = 'razor', r0 = r0, r1 = r1, guid = guid }
  end
  local function count_sel(ai)
    local n = 0
    for k = 0, reaper.CountEnvelopePointsEx(env, ai) - 1 do
      local _, _, _, _, _, s = reaper.GetEnvelopePointEx(env, ai, k)
      if s then n = n + 1 end
    end
    return n
  end
  local n = count_sel(-1)
  if n > 0 then return { ai = -1, mode = 'points', n = n } end
  for i = 0, nai - 1 do
    n = count_sel(i)
    if n > 0 then return check({ ai = i, A = ai_info(env, i), mode = 'points', n = n }) end
  end
  for i = 0, nai - 1 do
    local A = ai_info(env, i)
    if A.sel > 0 then return check({ ai = i, A = A, mode = 'item' }) end
  end
  return nil, 'Select points, an automation item, or draw a razor area on the envelope.'
end

-- straight-line value between stored points (used inside automation items)
local function lerp_eval(pts, t)
  local n = #pts
  if n == 0 then return nil end
  if t <= pts[1].t then return pts[1].v end
  if t >= pts[n].t then return pts[n].v end
  for i = 1, n - 1 do
    local a, b = pts[i], pts[i + 1]
    if t >= a.t and t <= b.t then
      if a.s == 1 or b.t - a.t < 1e-12 then return a.v end
      return a.v + (b.v - a.v) * (t - a.t) / (b.t - a.t)
    end
  end
  return pts[n].v
end

---------------------------------------------------------------- capture target
-- shared end of capture: sort, normalized values and x positions of the target points
local function finish(E, work)
  table.sort(work, function(a, b) return a.t < b.t end)
  local span = E.t1 - E.t0
  local ymin, ymax, n = 1e9, -1e9, 0
  for _, p in ipairs(work) do
    if p.tg then
      n = n + 1
      p.n = to_n(E, p.v)
      p.x = span > 0 and (p.t - E.t0) / span or 0
      p.r = math.random() * 2 - 1        -- fixed per drag, so the JITTER preview doesn't flicker
      if p.n < ymin then ymin = p.n end
      if p.n > ymax then ymax = p.n end
    end
  end
  if n == 0 then ymin, ymax = 0.5, 0.5 end
  E.work, E.count, E.ymin, E.ymax = work, n, ymin, ymax
  E.wlo, E.whi = E.t0 - PAD, E.t1 + PAD
  return E
end

---------------------------------------------------------------- MIDI editor lanes (CC, pitch bend, channel pressure, velocity)
-- shapes: envelope 0 = linear, 1 = square; MIDI CC 0 = square, 1 = linear; 2..5 are the same
local function cc_shape(s) if s == 0 then return 1 elseif s == 1 then return 0 end return s or 1 end
local function env_shape(c) if c == 0 then return 1 elseif c == 1 then return 0 end return c end

local LANE_KIND = { [0x200] = 'vel', [0x201] = 'pb', [0x203] = 'cp' }
local KIND_NAME = { vel = 'Velocity', pb = 'Pitch bend', cp = 'Channel pressure' }

-- active MIDI editor + its last clicked lane
local function midi_lane()
  local ed = reaper.MIDIEditor_GetActive()
  if not ed then return nil, 'No MIDI editor open.' end
  local take = reaper.MIDIEditor_GetTake(ed)
  if not take or not reaper.ValidatePtr(take, 'MediaItem_Take*') then return nil, 'The MIDI editor shows no take.' end
  local lane = reaper.MIDIEditor_GetSetting_int(ed, 'last_clicked_cc_lane')
  local M = { ed = ed, take = take, lane = lane }
  if lane >= 0 and lane <= 127 then
    M.kind, M.name = 'cc', 'CC' .. lane
  elseif LANE_KIND[lane] then
    M.kind = LANE_KIND[lane]; M.name = KIND_NAME[M.kind]
  elseif lane < 0 then
    return nil, 'Click a CC, pitch bend or velocity lane in the MIDI editor.'
  else
    return nil, 'Lane not supported: use velocity, pitch bend, channel pressure or CC 0-127 (no 14-bit).'
  end
  return M
end

-- raw take events; a CC's bezier tension event (CCBZ) is kept with its CC. Last unit = end-of-source marker.
local function midi_parse(take)
  local _, buf = reaper.MIDI_GetAllEvts(take, '')
  local units, pos, ppq, n = {}, 1, 0, #buf
  while pos <= n - 8 do
    local off, flags, msg, np = string.unpack('i4Bs4', buf, pos)
    pos = np
    ppq = ppq + off
    local last = units[#units]
    if last and msg:byte(1) == 0xFF and msg:sub(3, 7) == 'CCBZ ' and last.ppq == ppq and not last.bez then
      last.bez = { flags = flags, msg = msg }
    else
      units[#units + 1] = { ppq = ppq, flags = flags, msg = msg }
    end
  end
  return units, buf
end

-- value + channel of a unit when it belongs to the lane
local function lane_value(kind, lane, u)
  local m = u.msg
  local b1 = m:byte(1)
  if not b1 then return end
  local st, ch = b1 & 0xF0, b1 & 0x0F
  if kind == 'cc' and st == 0xB0 and #m >= 3 and m:byte(2) == lane then return m:byte(3), ch
  elseif kind == 'pb' and st == 0xE0 and #m >= 3 then return m:byte(2) + m:byte(3) * 128, ch
  elseif kind == 'cp' and st == 0xD0 and #m >= 2 then return m:byte(2), ch
  elseif kind == 'vel' and st == 0x90 and #m >= 3 and m:byte(3) > 0 then return m:byte(3), ch
  end
end

local function lane_msg(E, ch, v)
  v = math.floor(v + 0.5)
  if E.kind == 'pb' then
    v = clamp(v, 0, 16383)
    return string.char(0xE0 | ch, v & 127, v >> 7)
  elseif E.kind == 'cp' then
    return string.char(0xD0 | ch, clamp(v, 0, 127))
  end
  return string.char(0xB0 | ch, E.lane, clamp(v, 0, 127))
end

local function capture_midi()
  local M, err = midi_lane()
  if not M then return nil, err end
  local take = M.take
  local units, raw = midi_parse(take)
  if #units == 0 then return nil, 'The take has no MIDI data.' end
  local E = { midi = true, take = take, ed = M.ed, item = reaper.GetMediaItemTake_Item(take), kind = M.kind,
              lane = M.lane, name = M.name, lin = true, mode = 0, toff = 0, ai = -1, units = units, raw = raw,
              dmin = 0, dmax = (M.kind == 'pb') and 16383 or 127, lanemark = {}, lanet = {} }
  if M.kind == 'vel' then E.dmin, E.vel = 1, true end
  E.gridqn = reaper.MIDI_GetGrid(take)
  local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local hasts = ts1 > ts0 + 1e-6

  local all, selch, nsel = {}, {}, 0
  for i = 1, #units - 1 do
    local u = units[i]
    local v, ch = lane_value(M.kind, M.lane, u)
    if v then
      local p = { t = reaper.MIDI_GetProjTimeFromPPQPos(take, u.ppq), v = v, s = 0, ten = 0,
                  sel = (u.flags & 1) ~= 0, mu = (u.flags & 2) ~= 0, ch = ch, ref = i }
      if not E.vel then
        p.s = env_shape((u.flags >> 4) & 7)
        if u.bez and #u.bez.msg >= 12 then p.ten = string.unpack('f', u.bez.msg, 9) end
      end
      all[#all + 1] = p
      if p.sel then nsel = nsel + 1; selch[ch] = true end
    end
  end
  local what = E.vel and 'notes' or 'events'
  if nsel == 0 and not hasts then return nil, 'Select ' .. what .. ' in this lane or make a time selection.' end
  E.sel_mode = nsel > 0

  if E.vel then   -- velocity: values only, notes never move
    local work = {}
    for _, p in ipairs(all) do
      if (nsel > 0 and p.sel) or (nsel == 0 and p.t >= ts0 - EPS and p.t < ts1 - EPS) then
        p.tg = true
        work[#work + 1] = p
      end
    end
    if #work == 0 then return nil, 'No notes in the time selection.' end
    table.sort(work, function(a, b) return a.t < b.t end)
    local f, l = work[1].t, work[#work].t
    local groups, lastt = 0, nil
    for _, p in ipairs(work) do
      if not lastt or p.t - lastt > 1e-4 then groups = groups + 1; lastt = p.t end
    end
    E.vfirst, E.vlast, E.groups = f, l, groups
    if nsel > 0 then
      E.t0, E.t1 = f, l
      E.cyc1 = groups > 1 and (l + (l - f) / (groups - 1)) or l   -- cycles span one step past the last note
    else
      E.t0, E.t1, E.cyc1 = ts0, ts1, ts1
    end
    E.orig = {}
    return finish(E, work)
  end

  -- CC / pitch bend / pressure: one channel
  local ch
  if nsel > 0 then
    local n = 0
    for c in pairs(selch) do n = n + 1; ch = c end
    if n > 1 then return nil, 'Selected events sit on several MIDI channels: select one channel.' end
  else
    local seen, n = {}, 0
    for _, p in ipairs(all) do
      if p.t >= ts0 - EPS and p.t <= ts1 + EPS and not seen[p.ch] then seen[p.ch] = true; n = n + 1; ch = p.ch end
    end
    if n ~= 1 then ch = reaper.MIDIEditor_GetSetting_int(M.ed, 'default_note_chan') end
  end
  E.ch = clamp(ch or 0, 0, 15)
  local work, orig = {}, {}
  for _, p in ipairs(all) do
    if p.ch == E.ch then
      work[#work + 1] = p
      E.lanemark[p.ref], E.lanet[p.ref] = true, p.t
    end
  end
  table.sort(work, function(a, b) return a.t < b.t end)
  for i, p in ipairs(work) do orig[i] = cp(p) end
  E.orig = orig
  E.eval = function(t) return lerp_eval(orig, t) end

  if nsel > 0 then
    local t0, t1
    for _, p in ipairs(work) do
      p.tg = p.sel
      if p.sel then
        if not t0 or p.t < t0 then t0 = p.t end
        if not t1 or p.t > t1 then t1 = p.t end
      end
    end
    E.t0, E.t1 = t0, t1
  else
    E.razor = { timesel = true }
    for _, p in ipairs(work) do p.tg = (p.t >= ts0 - EPS and p.t <= ts1 + EPS) end
    -- edge events on the current line (only where a CC already sets the value), so the outside stays put
    local function edge(t)
      local prev
      for _, o in ipairs(orig) do
        if math.abs(o.t - t) < 1e-4 then return end
        if o.t < t then prev = o end
      end
      if not prev then return end
      work[#work + 1] = { t = t, v = E.eval(t), s = prev.s, ten = prev.ten, sel = false, ch = E.ch, tg = true }
    end
    edge(ts0); edge(ts1)
    E.t0, E.t1 = ts0, ts1
  end
  return finish(E, work)
end

-- rebuild the take from the captured events: lane events in the write window replaced by pts
local function write_midi(E, pts)
  local take, units = E.take, E.units
  if pts == E.orig then
    reaper.MIDI_SetAllEvts(take, E.raw)
  else
    local tail = units[#units]
    local list = {}
    if E.vel then
      local nv = {}
      for _, p in ipairs(pts) do if p.ref then nv[p.ref] = clamp(math.floor(p.v + 0.5), 1, 127) end end
      for i = 1, #units - 1 do
        local u = units[i]
        if nv[i] then
          list[#list + 1] = { ppq = u.ppq, flags = u.flags, msg = u.msg:sub(1, 2) .. string.char(nv[i]) .. u.msg:sub(4), bez = u.bez }
        else
          list[#list + 1] = u
        end
      end
    else
      local lo, hi = E.wlo, E.whi
      local keep = {}
      for i = 1, #units - 1 do
        local t = E.lanemark[i] and E.lanet[i]
        if not (t and t >= lo and t < hi) then keep[#keep + 1] = { u = units[i], o = i } end
      end
      local new, at = {}, {}
      for _, p in ipairs(pts) do
        if p.t >= lo and p.t < hi then
          local ppq = math.floor(reaper.MIDI_GetPPQPosFromProjTime(take, p.t) + 0.5)
          if ppq > tail.ppq then ppq = tail.ppq end
          local c = cc_shape(p.s)
          local u = { ppq = ppq, flags = (p.sel and 1 or 0) | (p.mu and 2 or 0) | (c << 4), msg = lane_msg(E, p.ch or E.ch, p.v) }
          if c == 5 then u.bez = { flags = 0, msg = '\xFF\x0FCCBZ \0' .. string.pack('f', p.ten or 0) } end
          if at[ppq] then new[at[ppq]].u = u   -- two events on one tick: the later one wins
          else
            new[#new + 1] = { u = u, o = #units + #new + 1 }
            at[ppq] = #new
          end
        end
      end
      for _, x in ipairs(new) do keep[#keep + 1] = x end
      table.sort(keep, function(a, b)
        if a.u.ppq ~= b.u.ppq then return a.u.ppq < b.u.ppq end
        return a.o < b.o
      end)
      for i, x in ipairs(keep) do list[i] = x.u end
    end
    local parts, prev = {}, 0
    local function put(u)
      parts[#parts + 1] = string.pack('i4Bs4', u.ppq - prev, u.flags, u.msg)
      prev = u.ppq
      if u.bez then parts[#parts + 1] = string.pack('i4Bs4', 0, u.bez.flags, u.bez.msg) end
    end
    for _, u in ipairs(list) do put(u) end
    put(tail)
    reaper.MIDI_SetAllEvts(take, table.concat(parts))
  end
  reaper.MIDI_Sort(take)
  reaper.UpdateArrange()
end

---------------------------------------------------------------- source: envelope lane or MIDI editor lane
-- follows what you touched last (selected envelope / razor / points vs. MIDI lane / events); the switch forces it
local src = 'env'
local sig_e, sig_m
local rebase = false   -- set after our own writes, so they don't flip the source

local function sig_env()
  local env = reaper.GetSelectedEnvelope(0)
  if not env then return '' end
  local tr = reaper.Envelope_GetParentTrack(env)
  local rz, ok = ''
  if tr then ok, rz = reaper.GetSetMediaTrackInfo_String(tr, 'P_RAZOREDITS', '', false) end
  local n = 0
  for ai = -1, reaper.CountAutomationItems(env) - 1 do
    for i = 0, reaper.CountEnvelopePointsEx(env, ai) - 1 do
      local _, _, _, _, _, s = reaper.GetEnvelopePointEx(env, ai, i)
      if s then n = n + 1 end
    end
  end
  return tostring(env) .. '|' .. rz .. '|' .. n
end

local function sig_midi()
  local ed = reaper.MIDIEditor_GetActive()
  if not ed then return '' end
  local take = reaper.MIDIEditor_GetTake(ed)
  if not take or not reaper.ValidatePtr(take, 'MediaItem_Take*') then return '' end
  local _, h = reaper.MIDI_GetHash(take, false, '')
  return tostring(take) .. '|' .. reaper.MIDIEditor_GetSetting_int(ed, 'last_clicked_cc_lane') .. '|' .. h
         .. '|' .. reaper.MIDI_EnumSelCC(take, -1) .. '|' .. reaper.MIDI_EnumSelNotes(take, -1)
end

local function update_source()
  local se, sm = sig_env(), sig_midi()
  if sig_e == nil then
    src = (se == '' and sm ~= '') and 'midi' or 'env'
  elseif not rebase then
    if sm ~= sig_m and sm ~= '' then src = 'midi'
    elseif se ~= sig_e and se ~= '' then src = 'env' end
  end
  -- the current source is gone (MIDI editor closed / no envelope) but the other one exists: switch
  if src == 'midi' and sm == '' and se ~= '' then src = 'env'
  elseif src == 'env' and se == '' and sm ~= '' then src = 'midi' end
  sig_e, sig_m, rebase = se, sm, false
end

local function capture_env()
  local env = reaper.GetSelectedEnvelope(0)
  if not env then return nil, 'Click an envelope lane first.' end
  local E = env_info(env)
  if E.name == 'Tempo map' then return nil, 'Tempo map is not supported.' end
  local T, err = resolve(env, E.track)
  if not T then return nil, err end
  local ai = T.ai
  E.ai, E.A = ai, T.A

  local orig, work = {}, {}
  for i = 0, reaper.CountEnvelopePointsEx(env, ai) - 1 do
    local _, t, v, s, ten, sel = reaper.GetEnvelopePointEx(env, ai, i)
    orig[#orig + 1] = { t = t, v = v, s = s, ten = ten, sel = sel }
    work[#work + 1] = { t = t, v = v, s = s, ten = ten, sel = sel }
    -- widen range if points sit outside; volume lanes keep their top (VOLUME LANES switch) = hard ceiling:
    -- points above it come down to it as soon as a value strip moves them
    local d = E.lin and v or reaper.ScaleFromEnvelopeMode(E.mode, v)
    if d < E.dmin then E.dmin = d end
    if d > E.dmax and not E.lin then E.dmax = d end
  end
  table.sort(orig, function(a, b) return a.t < b.t end)
  E.orig = orig

  local function eval(t)
    if ai >= 0 and #orig > 0 then return lerp_eval(orig, t) end
    local _, v = reaper.Envelope_Evaluate(env, t, 48000, 1)
    return v
  end
  E.eval = eval

  if T.mode == 'razor' then
    local r0, r1 = T.r0, T.r1
    local blo = E.A and E.A.pos or 0
    local bhi = E.A and (E.A.pos + E.A.len) or math.huge
    E.razor = { guid = T.guid }
    for _, p in ipairs(work) do p.tg = (p.t >= r0 - EPS and p.t <= r1 + EPS) end
    local function near(t) for _, p in ipairs(work) do if math.abs(p.t - t) < 1e-4 then return true end end end
    local add = {}
    if not near(r0) then add[#add + 1] = { t = r0, v = eval(r0), s = 0, ten = 0, sel = false, tg = true } end
    if not near(r1) then add[#add + 1] = { t = r1, v = eval(r1), s = 0, ten = 0, sel = false, tg = true } end
    if r0 - GUARD >= blo and not near(r0 - GUARD) then
      add[#add + 1] = { t = r0 - GUARD, v = eval(r0 - GUARD), s = 0, ten = 0, sel = false, tg = false }
    end
    if r1 + GUARD <= bhi and not near(r1 + GUARD) then
      add[#add + 1] = { t = r1 + GUARD, v = eval(r1 + GUARD), s = 0, ten = 0, sel = false, tg = false }
    end
    for _, p in ipairs(add) do work[#work + 1] = p end
    E.t0, E.t1 = r0, r1
  elseif T.mode == 'item' then
    for _, p in ipairs(work) do p.tg = true end
    E.item = true
    E.t0, E.t1 = E.A.pos, E.A.pos + E.A.len
  else
    local t0, t1
    for _, p in ipairs(work) do
      p.tg = p.sel
      if p.sel then
        if not t0 or p.t < t0 then t0 = p.t end
        if not t1 or p.t > t1 then t1 = p.t end
      end
    end
    if not t0 then return nil, 'Select envelope points or draw a razor area on the envelope.' end
    E.t0, E.t1 = t0, t1
  end
  return finish(E, work)
end

local function capture()
  update_source()
  if src == 'midi' then return capture_midi() end
  return capture_env()
end

---------------------------------------------------------------- operations
-- ops that change the time span overwrite non-target points inside the new span
local DROP = { stretchL = true, stretchR = true, movet = true }

local NAMES = {
  stretchL = 'Stretch L', stretchR = 'Stretch R', movet = 'Move time', warpt = 'Warp time',
  tiltL = 'Tilt L', tiltR = 'Tilt R', scaleT = 'Scale top', scaleB = 'Scale bottom',
  comp = 'Compress/expand', movev = 'Move value', warpv = 'Warp value',
  flip = 'Flip values', reverse = 'Reverse', bend = 'Bend', shape = 'Shape', addpts = 'Add points',
  gen = 'Generate', reduce = 'Reduce points', jitter = 'Jitter', rotate = 'Rotate',
}

-- REAPER point shapes (index = shape value)
local SHAPES = { [0] = 'Linear', 'Square', 'Slow start/end', 'Fast start', 'Fast end', 'Bezier' }
local SHAPE_BTN = { [0] = 'LINEAR', 'SQUARE', 'SLOW S/E', 'FAST START', 'FAST END', 'BEZIER' }
local shape_pick = 0

---------------------------------------------------------------- generate (writes a preset shape into the target)
local GEN_NAMES = { [0] = 'Ramp up', 'Ramp down', 'Swell', 'Fade', 'Sine', 'Triangle',
                    'Saw up', 'Saw down', 'Square', 'Random steps', 'Random smooth' }
local GEN_COMBO = table.concat({ GEN_NAMES[0], table.unpack(GEN_NAMES) }, '\0') .. '\0'

local function generate(E)
  local t0, t1 = E.t0, E.t1
  local span = t1 - t0
  if span <= 0 then return nil end
  local lo, hi = clamp(cfg.lo, 0, 100) / 100, clamp(cfg.hi, 0, 100) / 100
  local res = {}
  for _, p in ipairs(E.work) do   -- keep everything outside the target span
    if not p.tg and not (p.t > t0 - EPS and p.t < t1 + EPS) then
      res[#res + 1] = cp(p)
    end
  end
  local sel = not E.razor
  local function add(t, n, s) res[#res + 1] = { t = t, v = from_n(E, n), s = s or 0, ten = 0, sel = sel, ch = E.ch } end

  local g, c = cfg.gen, math.max(1, cfg.cycles)
  if g == 0 then add(t0, lo); add(t1, hi)                       -- ramp up
  elseif g == 1 then add(t0, hi); add(t1, lo)                   -- ramp down
  elseif g == 2 then add(t0, lo, 4); add(t1, hi)                -- swell = fast end
  elseif g == 3 then add(t0, hi, 3); add(t1, lo)                -- fade = fast start
  elseif g == 4 or g == 5 or g == 8 then                        -- sine / triangle / square
    local s = (g == 4) and 2 or (g == 5) and 0 or 1
    local half = span / (2 * c)
    for k = 0, 2 * c do add(t0 + k * half, (k % 2 == 0) and lo or hi, s) end
  elseif g == 6 or g == 7 then                                  -- saw up / down
    local len = span / c
    local a, b = (g == 6) and lo or hi, (g == 6) and hi or lo
    local gap = math.min(0.0005, len * 0.01)
    for k = 0, c - 1 do
      local ts = t0 + k * len
      add(ts, a)
      add(ts + len - gap, b)
    end
    add(t1, a)
  else                                                          -- random steps / smooth (spacing = POINTS menu)
    local s = (g == 9) and 1 or 2
    add(t0, lo + math.random() * (hi - lo), s)
    for _, t in ipairs(grid_times(t0, t1, E.toff, E.gridqn)) do add(t, lo + math.random() * (hi - lo), s) end
    add(t1, lo + math.random() * (hi - lo), s)
  end
  return res, GEN_NAMES[g], t0, t1
end

-- velocity GENERATE: the shape read at each note (chords = one step); ramps run first to last note,
-- cycles run over the time selection (selected notes: up to one step past the last note)
local function gen_vel(E)
  local lo, hi = clamp(cfg.lo, 0, 100) / 100, clamp(cfg.hi, 0, 100) / 100
  local g, c = cfg.gen, math.max(1, cfg.cycles)
  -- a wave needs 2+ notes per cycle, else every note hits the same spot of its cycle (aliasing)
  local cmax, note = math.max(1, (E.groups or 2) // 2), ''
  if g >= 4 and g <= 8 and c > cmax then
    c, note = cmax, string.format(' (cycles capped at %d: 2 notes per cycle minimum)', cmax)
  end
  local f, l = E.vfirst, E.vlast
  local c0, c1 = E.t0, E.cyc1 or E.t1
  local res, rnd, lastt = {}, 0, nil
  for _, p in ipairs(E.work) do
    local xr = (l > f) and (p.t - f) / (l - f) or 0
    local ph = ((c1 > c0) and (p.t - c0) / (c1 - c0) * c or 0) % 1
    local y
    if g == 0 then y = xr
    elseif g == 1 then y = 1 - xr
    elseif g == 2 then y = xr * xr
    elseif g == 3 then y = (1 - xr) ^ 2
    elseif g == 4 then y = 0.5 - 0.5 * math.cos(2 * math.pi * ph)
    elseif g == 5 then y = ph < 0.5 and ph * 2 or 2 - ph * 2
    elseif g == 6 then y = ph
    elseif g == 7 then y = 1 - ph
    elseif g == 8 then y = ph < 0.5 and 0 or 1
    else
      if not lastt or p.t - lastt > 1e-4 then rnd = math.random() end
      y = rnd
    end
    lastt = p.t
    local q = cp(p)
    q.v = from_n(E, lo + (hi - lo) * y)
    res[#res + 1] = q
  end
  return res, GEN_NAMES[g] .. note, E.t0, E.t1
end

-- velocity ROTATE: the velocity pattern shifts by whole notes (chords move together), notes stay put
local function rotate_vel(E, a)
  local groups, lastt = {}, nil
  for _, p in ipairs(E.work) do
    if not lastt or p.t - lastt > 1e-4 then groups[#groups + 1] = {} end
    local grp = groups[#groups]
    grp[#grp + 1] = p
    lastt = p.t
  end
  local K = #groups
  local k = math.floor(a * K + 0.5)
  local res = {}
  for i, grp in ipairs(groups) do
    local from = groups[((i - 1 - k) % K) + 1]
    for j, p in ipairs(grp) do
      local q = cp(p)
      q.v = (from[j] or from[1]).v
      res[#res + 1] = q
    end
  end
  return res, string.format('%+d notes', k), E.t0, E.t1
end

-- what works on the velocity lane (time ops would move notes: greyed out)
local VEL_OK = { tiltL = true, tiltR = true, scaleT = true, scaleB = true, comp = true, movev = true,
                 warpv = true, flip = true, jitter = true, gen = true, rotate = true }

-- Ramer-Douglas-Peucker on value error: keeps the points that bend the line by more than tol
local function rdp(pts, i, j, tol, keep)
  if j <= i + 1 then return end
  local a, b = pts[i], pts[j]
  local dt = b.t - a.t
  local worst, wi = -1, nil
  for k = i + 1, j - 1 do
    local p = pts[k]
    local y = (dt > 0 and a.s ~= 1) and (a.y + (b.y - a.y) * (p.t - a.t) / dt) or a.y
    local d = math.abs(p.y - y)
    if p.s ~= 0 then d = math.max(d, tol * 2) end   -- curved/square points carry shape: keep them
    if d > worst then worst, wi = d, k end
  end
  if worst > tol then
    keep[wi] = true
    rdp(pts, i, wi, tol, keep)
    rdp(pts, wi, j, tol, keep)
  end
end

-- ROTATE: slide the pattern inside the target span; what leaves one end comes back at the other
local function rotate(E, a)
  local t0, t1 = E.t0, E.t1
  local P = t1 - t0
  local res = {}
  if P <= 0 then   -- single point: nothing to rotate
    for _, p in ipairs(E.work) do res[#res + 1] = cp(p) end
    return res, 'needs 2+ points', t0, t1
  end
  -- the loop = all target points except the end point (the end is the start again);
  -- non-target points always stay (in points mode: unselected points between the selected ones)
  local loop = {}
  for _, p in ipairs(E.work) do
    if p.tg then
      if p.t < t1 - 1e-4 then loop[#loop + 1] = p end
    else
      res[#res + 1] = cp(p)
    end
  end
  if #loop == 0 then
    for _, p in ipairs(E.work) do res[#res + 1] = cp(p) end
    return res, 'needs 2+ points', t0, t1
  end

  -- step in the pattern's own points: pick the point nearest to the drag and bring it to the start,
  -- so a point always sits exactly on both edges and curved segments are never split
  local want = (a * P) % P
  local d, best = 0, math.huge
  for _, p in ipairs(loop) do
    local cand = (P - (p.t - t0)) % P
    local dist = math.abs(cand - want)
    dist = math.min(dist, P - dist)
    if dist < best then best, d = dist, cand end
  end

  local head
  for _, p in ipairs(loop) do
    local nt = t0 + ((p.t - t0 + d) % P)
    if math.abs(nt - t1) < 1e-6 then nt = t0 end
    local q = cp(p)
    q.t = nt
    res[#res + 1] = q
    if math.abs(nt - t0) < 1e-6 then head = q end
  end
  if head then   -- close the loop: the end point repeats the start point
    local q = cp(head)
    q.t, q.ref = t1, nil
    res[#res + 1] = q
  end

  local off = E.toff or 0
  local beats = reaper.TimeMap2_timeToQN(0, t0 + off + d) - reaper.TimeMap2_timeToQN(0, t0 + off)
  return res, string.format('%.2f beats', beats), t0, t1
end

local function apply(E, op, a)
  if E.vel then
    if op == 'gen' then return gen_vel(E) end
    if op == 'rotate' then return rotate_vel(E, a) end
    if not VEL_OK[op] then
      local res = {}
      for _, p in ipairs(E.work) do res[#res + 1] = cp(p) end
      return res, 'not on velocity', E.t0, E.t1
    end
  end
  if op == 'gen' then return generate(E) end
  if op == 'rotate' then return rotate(E, a) end
  local t0, t1 = E.t0, E.t1
  local span = t1 - t0
  local ymin, ymax = E.ymin, E.ymax
  local tf, vf, label
  local snap = cfg.snap
  local off = E.toff or 0
  local function snapt(t)
    local g = E.gridqn
    if g and g > 0 then   -- MIDI lanes snap to the MIDI editor grid
      local q = reaper.TimeMap2_timeToQN(0, t)
      return reaper.TimeMap2_QNToTime(0, math.floor(q / g + 0.5) * g)
    end
    return reaper.SnapToGrid(0, t + off) - off
  end
  -- automation items: time moves stay inside the item (no points piled up on its edge)
  local blo = E.A and E.A.pos or -math.huge
  local bhi = E.A and (E.A.pos + E.A.len) or math.huge

  if op == 'stretchL' or op == 'stretchR' then
    local anchor = (op == 'stretchL') and t1 or t0
    local edge   = (op == 'stretchL') and t0 or t1
    local k = 2 ^ (2 * a)
    if span > 0 then
      local ne = anchor + (edge - anchor) * k
      if snap then ne = snapt(ne) end
      ne = clamp(ne, blo, bhi)
      if op == 'stretchL' then ne = math.min(ne, anchor - 0.001) else ne = math.max(ne, anchor + 0.001) end
      if op == 'stretchL' and ne < 0 then ne = 0 end
      k = (ne - anchor) / (edge - anchor)
    end
    tf = function(p) return anchor + (p.t - anchor) * k end
    label = string.format('x%.2f', k)
  elseif op == 'movet' then
    local d = a * math.max(span, 1) * 2
    if snap then d = snapt(t0 + d) - t0 end
    if t0 + d < 0 then d = -t0 end
    if E.A then d = clamp(d, blo - t0, bhi - t1) end
    tf = function(p) return p.t + d end
    label = string.format('%+.3f s', d)
  elseif op == 'warpt' then
    local pw = 2 ^ (-2 * a)
    tf = function(p) return t0 + span * (p.x ^ pw) end
    label = string.format('%+.0f%%', a * 100)
  elseif op == 'reverse' then
    tf = function(p) return t0 + t1 - p.t end
    label = ''
  elseif op == 'tiltL' then
    vf = function(p) return p.n + a * curve(1 - p.x) end
    label = string.format('%+.0f%%', a * 100)
  elseif op == 'tiltR' then
    vf = function(p) return p.n + a * curve(p.x) end
    label = string.format('%+.0f%%', a * 100)
  elseif op == 'scaleT' then
    local k = 1 + a
    vf = function(p) return ymin + (p.n - ymin) * k end
    label = string.format('%.0f%%', k * 100)
  elseif op == 'scaleB' then
    local k = 1 + a
    vf = function(p) return ymax + (p.n - ymax) * k end
    label = string.format('%.0f%%', k * 100)
  elseif op == 'comp' then
    local k, c = 1 + a, (ymin + ymax) / 2
    vf = function(p) return c + (p.n - c) * k end
    label = string.format('%.0f%%', k * 100)
  elseif op == 'movev' then
    vf = function(p) return p.n + a end
    label = string.format('%+.0f%%', a * 100)
  elseif op == 'warpv' then
    local pw, r = 2 ^ (-2 * a), ymax - ymin
    vf = function(p)
      if r < 1e-9 then return p.n end
      return ymin + r * (((p.n - ymin) / r) ^ pw)
    end
    label = string.format('%+.0f%%', a * 100)
  elseif op == 'flip' then
    vf = function(p) return ymax + ymin - p.n end
    label = ''
  elseif op == 'bend' then
    label = string.format('%+.0f%%', a * 100)
  elseif op == 'shape' then
    label = SHAPES[shape_pick]
  elseif op == 'addpts' or op == 'reduce' then
    label = ''
  elseif op == 'jitter' then
    local amt = math.abs(a) * 0.5
    vf = function(p) return p.n + amt * (p.r or 0) end
    label = string.format('+/-%.0f%%', amt * 100)
  end

  local nt0 = tf and tf({ t = t0, x = 0 }) or t0
  local nt1 = tf and tf({ t = t1, x = 1 }) or t1
  local lo, hi = math.min(nt0, nt1), math.max(nt0, nt1)

  local res, tg = {}, {}
  for _, p in ipairs(E.work) do
    if p.tg then
      local q = cp(p)
      if tf then q.t = tf(p); if E.A then q.t = clamp(q.t, E.A.pos, E.A.pos + E.A.len) end end
      if vf then q.v = from_n(E, vf(p)) end
      res[#res + 1] = q
      tg[#tg + 1] = q
    elseif not (DROP[op] and p.t > lo - EPS and p.t < hi + EPS) then
      res[#res + 1] = cp(p)
    end
  end

  if op == 'reverse' then
    -- a point's shape belongs to the segment after it: shift shapes so each segment keeps its curve
    local n = #tg
    local src = {}
    for i = 1, n do src[i] = { s = tg[i].s, ten = tg[i].ten } end
    for i = 2, n do tg[i].s, tg[i].ten = src[i - 1].s, -src[i - 1].ten end
    tg[1].ten = -tg[1].ten
  end

  if op == 'addpts' then
    -- new points sit exactly on the current line, so nothing changes until you shape them
    local added = 0
    for _, t in ipairs(grid_times(t0, t1, E.toff, E.gridqn)) do
      local clash = false
      for _, q in ipairs(res) do
        if math.abs(q.t - t) < 1e-3 then clash = true; break end
      end
      local v = not clash and E.eval(t)
      if v then
        res[#res + 1] = { t = t, v = v, s = 0, ten = 0, sel = true, ch = E.ch }
        added = added + 1
      end
    end
    if added > 0 then
      -- curves are now carried by the points themselves: segments become linear
      local last = E.razor and #tg - 1 or #tg
      for i = 1, last do tg[i].s, tg[i].ten = 0, 0 end
    end
    label = added .. ' new'
  end

  if op == 'reduce' then
    -- drop points the line doesn't need (value error <= 1% of the lane); first + last always stay
    local n0 = #tg
    if n0 > 2 then
      local pts = {}
      for i, q in ipairs(tg) do pts[i] = { t = q.t, y = to_n(E, q.v), s = q.s } end
      local keep = { [1] = true, [n0] = true }
      rdp(pts, 1, n0, 0.01, keep)
      local drop, kept = {}, 0
      for i, q in ipairs(tg) do
        if keep[i] then kept = kept + 1 else drop[q] = true end
      end
      local out = {}
      for _, q in ipairs(res) do if not drop[q] then out[#out + 1] = q end end
      res = out
      label = string.format('%d -> %d points', n0, kept)
    else
      label = 'nothing to reduce'
    end
  end

  if op == 'bend' or op == 'shape' then
    -- a point's shape = the segment after it; in a razor area the last point's segment leaves the area
    local last = E.razor and #tg - 1 or #tg
    for i = 1, last do
      local q = tg[i]
      if op == 'bend' then
        q.s, q.ten = 5, clamp(a, -1, 1)
      else
        q.s = shape_pick
        if shape_pick ~= 5 then q.ten = 0 end
      end
    end
  end

  return res, label, lo, hi
end

---------------------------------------------------------------- write
local function write(E, pts)
  rebase = true   -- our own change: don't let it flip the ENVELOPE / MIDI source
  if E.midi then return write_midi(E, pts) end
  local lo, hi = E.wlo, E.whi
  reaper.PreventUIRefresh(1)
  reaper.DeleteEnvelopePointRangeEx(E.env, E.ai, lo, hi)
  for _, p in ipairs(pts) do
    if p.t >= lo and p.t < hi then
      reaper.InsertEnvelopePointEx(E.env, E.ai, p.t, p.v, p.s, p.ten, p.sel, true)
    end
  end
  reaper.Envelope_SortPointsEx(E.env, E.ai)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

local function grow_window(E, lo, hi)
  if lo - PAD < E.wlo then E.wlo = lo - PAD end
  if hi + PAD > E.whi then E.whi = hi + PAD end
end

local function set_razor(E, a, b)
  local _, rz = reaper.GetSetMediaTrackInfo_String(E.track, 'P_RAZOREDITS', '', false)
  local out = {}
  for x, y, g in rz:gmatch('(%S+) (%S+) "([^"]*)"') do
    if g == E.razor.guid then x, y = string.format('%.14f', a), string.format('%.14f', b) end
    out[#out + 1] = x .. ' ' .. y .. ' "' .. g .. '"'
  end
  reaper.GetSetMediaTrackInfo_String(E.track, 'P_RAZOREDITS', table.concat(out, ' '), true)
end

local status, status_err = '', false

local function commit(E, op, res, label, lo, hi)
  local undo = 'Envelope shaper: ' .. NAMES[op] .. (label ~= '' and (' ' .. label) or '')
  if E.midi then
    write(E, res)
    -- time selection follows a stretch/move, like the razor area on envelopes
    if E.razor and (lo ~= E.t0 or hi ~= E.t1) then reaper.GetSet_LoopTimeRange(true, false, lo, hi, false) end
    reaper.Undo_OnStateChange_Item(0, undo, E.item)
    status, status_err = NAMES[op] .. (label ~= '' and (': ' .. label) or '') .. '  (' .. E.name .. ')', false
    return
  end
  reaper.Undo_BeginBlock2(0)
  write(E, res)
  if E.razor and (lo ~= E.t0 or hi ~= E.t1) then set_razor(E, lo, hi) end
  reaper.Undo_EndBlock2(0, undo, -1)
  status, status_err = NAMES[op] .. (label ~= '' and (': ' .. label) or '') .. '  (' .. E.name .. ')', false
end

local function one_shot(op)
  local E, err = capture()
  if not E then status, status_err = err, true; return end
  local res, label, lo, hi = apply(E, op, 1)
  if not res then status, status_err = 'Needs a range: a razor area or 2+ selected points.', true; return end
  grow_window(E, lo, hi)
  commit(E, op, res, label, lo, hi)
end

-- unselect every point on the selected lane's track (all its envelopes + automation items), one undo step
local function deselect_all()
  if src == 'midi' then   -- MIDI: unselect every event in the take
    local M, err = midi_lane()
    if not M then status, status_err = err, true; return end
    reaper.MIDI_SelectAll(M.take, false)
    rebase = true
    reaper.Undo_OnStateChange_Item(0, 'Envelope shaper: Deselect events', reaper.GetMediaItemTake_Item(M.take))
    reaper.UpdateArrange()
    status, status_err = 'All events in the take unselected.', false
    return
  end
  local env = reaper.GetSelectedEnvelope(0)
  if not env then status, status_err = 'Click an envelope lane first.', true; return end
  local envs = { env }
  local tr = reaper.Envelope_GetParentTrack(env)
  if tr then
    envs = {}
    for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do envs[#envs + 1] = reaper.GetTrackEnvelope(tr, i) end
  end
  local count = 0
  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)
  for _, e in ipairs(envs) do
    for ai = -1, reaper.CountAutomationItems(e) - 1 do
      for i = 0, reaper.CountEnvelopePointsEx(e, ai) - 1 do
        local _, _, _, _, _, sel = reaper.GetEnvelopePointEx(e, ai, i)
        if sel then
          reaper.SetEnvelopePointEx(e, ai, i, nil, nil, nil, nil, false, true)
          count = count + 1
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(0, 'Envelope shaper: Deselect points', -1)
  status, status_err = count .. ' point' .. (count == 1 and '' or 's') .. ' unselected.', false
end

---------------------------------------------------------------- target line (refreshed a few times per second)
local drag = nil   -- running strip drag: { op, E, a, raw, mx, res, label, lo, hi, cancelled, dead }
local target_txt, target_ok, target_next = '', false, 0
local target_vol = nil   -- env info when the selected lane is a volume lane (GENERATE shows dB)

-- slider text for GENERATE Low/High: dB on volume lanes, else % of the lane
local target_fx = nil    -- { tr|take, fx, param } when the lane is an FX parameter (GENERATE shows plugin units)

-- the plugin's own text for a normalized value (e.g. "1.20 kHz"); nil if the plugin can't format it
local function fx_text(F, n)
  local ok, buf
  if F.tr then
    ok, buf = reaper.TrackFX_FormatParamValueNormalized(F.tr, F.fx, F.param, n, '')
  else
    ok, buf = reaper.TakeFX_FormatParamValueNormalized(F.take, F.fx, F.param, n, '')
  end
  if ok and buf and buf ~= '' then return buf end
end

local target_midi = nil  -- { kind, dmin, dmax } when the source is a MIDI lane (Low/High show MIDI values)

local function midi_level(pct)
  local M = target_midi
  return math.floor(M.dmin + clamp(pct, 0, 100) / 100 * (M.dmax - M.dmin) + 0.5)
end

local function level_fmt(prefix, pct)
  if target_midi then
    local v = midi_level(pct)
    if target_midi.kind == 'pb' then return string.format('%s %+d', prefix, v - 8192) end
    return string.format('%s %d', prefix, v)
  end
  if target_fx then
    local txt = fx_text(target_fx, clamp(pct, 0, 100) / 100)
    if txt then return prefix .. ' ' .. (txt:gsub('%%', '%%%%')) end
    return prefix .. ' %.0f%%'
  end
  local E = target_vol
  if not E then return prefix .. ' %.0f%%' end
  local d = E.dmin + clamp(pct, 0, 100) / 100 * (E.dmax - E.dmin)   -- raw lane value
  local amp = reaper.ScaleFromEnvelopeMode(E.mode, d)
  if amp <= 1e-6 then return prefix .. ' -inf dB' end
  return string.format('%s %.1f dB', prefix, 20 * math.log(amp, 10))
end

local function refresh_target()
  local now = reaper.time_precise()
  if now < target_next then return end
  target_next = now + 0.3
  if not drag then update_source() end
  target_midi = nil
  if src == 'midi' then
    target_vol, target_fx = nil, nil
    local M, err = midi_lane()
    if not M then target_txt, target_ok = 'MIDI editor\n' .. err, false; return end
    target_midi = { kind = M.kind, dmin = (M.kind == 'vel') and 1 or 0, dmax = (M.kind == 'pb') and 16383 or 127 }
    local _, tn = reaper.GetTrackName(reaper.GetMediaItemTake_Track(M.take))
    local tk = reaper.GetTakeName(M.take)
    local head = tn .. ' / ' .. (tk ~= '' and (tk .. ' / ') or '') .. M.name
    local E, e2 = capture_midi()
    if not E then target_txt, target_ok = head .. '\n' .. e2, false; return end
    local n = 0
    for _, p in ipairs(E.work) do if p.tg and p.ref then n = n + 1 end end
    local unit = E.vel and 'note' or 'event'
    local what
    if E.sel_mode then
      what = string.format('%d selected %s%s', n, unit, n == 1 and '' or 's')
    else
      local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
      what = string.format('Time selection %.3f - %.3f s: %d %s%s', ts0, ts1, n, unit, n == 1 and '' or 's')
    end
    if not E.vel then what = what .. string.format('  |  ch %d', E.ch + 1) end
    target_txt, target_ok = head .. '\n' .. what, true
    return
  end
  local env = reaper.GetSelectedEnvelope(0)
  if not env then
    target_txt, target_ok, target_vol, target_fx = 'No envelope selected: click an envelope lane.', false, nil, nil
    return
  end
  do
    local ftr, ffx, fpar = reaper.Envelope_GetParentTrack(env)
    if ftr and ffx and ffx >= 0 then
      target_fx = { tr = ftr, fx = ffx, param = fpar }
    else
      local tk, tfx, tpar = reaper.Envelope_GetParentTake(env)
      target_fx = (tk and tfx and tfx >= 0) and { take = tk, fx = tfx, param = tpar } or nil
    end
  end
  local _, name = reaper.GetEnvelopeName(env)
  local tr = reaper.Envelope_GetParentTrack(env)
  local where = ''
  if tr then
    local _, tn = reaper.GetTrackName(tr)
    where = tn .. ' / '
  end
  target_vol = name:lower():find('volume') and env_info(env) or nil
  local T, err = resolve(env, tr)
  if not T then target_txt, target_ok = where .. name .. '\n' .. err, false; return end
  local what
  if T.mode == 'razor' then what = string.format('Razor %.3f - %.3f s', T.r0, T.r1)
  elseif T.mode == 'item' then what = 'Whole automation item'
  else what = string.format('%d selected point%s', T.n, T.n == 1 and '' or 's') end
  if T.A then
    what = what .. '  |  in automation item ' .. (T.A.idx + 1)
    if T.A.pooled > 1 then what = what .. string.format('\nPooled: changes all %d copies', T.A.pooled) end
  end
  target_txt, target_ok = where .. name .. '\n' .. what, true
end

---------------------------------------------------------------- detents (round values; Shift = in between)
local function round_to(x, step) return math.floor(x / step + 0.5) * step end

-- strips: amount -1..1 rounded so the readout lands on round values
local function detent_amount(op, a)
  if op == 'movet' or op == 'rotate' then return a end            -- grid snap / own steps
  if op == 'stretchL' or op == 'stretchR' then                    -- x0.25 .. x4 in 0.05 steps
    local k = math.max(0.25, round_to(2 ^ (2 * a), 0.05))
    return clamp(math.log(k, 2) / 2, -1, 1)
  end
  if op == 'jitter' then return round_to(a, 0.1) end              -- 5% steps of the readout
  return round_to(a, 0.05)                                        -- 5% steps
end

-- Low/High sliders: whole dB on volume lanes, whole % on % lanes, free on plugin units
local function detent_level(pct)
  if target_midi then   -- whole MIDI values
    local M = target_midi
    return clamp((midi_level(pct) - M.dmin) / (M.dmax - M.dmin) * 100, 0, 100)
  end
  if ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) or target_fx then return pct end
  local E = target_vol
  if not E then return round_to(pct, 1) end
  if pct <= 0.5 then return 0 end
  local d = E.dmin + pct / 100 * (E.dmax - E.dmin)   -- raw lane value
  local amp = reaper.ScaleFromEnvelopeMode(E.mode, d)
  if amp <= 1e-6 then return 0 end
  amp = 10 ^ (round_to(20 * math.log(amp, 10), 1) / 20)
  d = reaper.ScaleToEnvelopeMode(E.mode, amp)
  return clamp((d - E.dmin) / (E.dmax - E.dmin) * 100, 0, 100)
end

---------------------------------------------------------------- drag strips

local COL = {
  bg     = 0x24272BFF, bg_hov = 0x2E3237FF, border = 0x4A5058FF,
  center = 0x6A7078FF, fill   = 0xE0A030B0, text   = 0xE6E6E6FF,
  value  = 0xFFC860FF, ok     = 0x9ED39EFF, err    = 0xFF8070FF,
  sw_on  = 0xE0A030FF, sw_txt = 0x111111FF, win = 0x1B1D21FF,
}

local function cancel_drag()
  if drag and drag.E and not drag.cancelled then
    write(drag.E, drag.E.orig)
    drag.cancelled = true
    status, status_err = 'Cancelled.', false
  end
end

local function strip(op, label, tip)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = 24
  ImGui.InvisibleButton(ctx, '##' .. op, w, h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local mx = ImGui.GetMousePos(ctx)

  if ImGui.IsItemActivated(ctx) then
    local E, err = capture()
    if E then
      drag = { op = op, E = E, a = 0, raw = 0, mx = mx }
    else
      drag = { op = op, dead = true }
      status, status_err = err, true
    end
  end

  local mine = drag and drag.op == op
  if active and mine and drag.E and not drag.cancelled then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      cancel_drag()
    else
      local shift = ImGui.IsKeyDown(ctx, ImGui.Mod_Shift)
      drag.raw = clamp(drag.raw + (mx - drag.mx) / (w * 0.5) * (shift and 0.2 or 1), -1, 1)
      local na = shift and drag.raw or detent_amount(op, drag.raw)   -- Shift = fine + in between
      drag.mx = mx
      if na ~= drag.a or not drag.res then
        drag.a = na
        local res, lbl, lo, hi = apply(drag.E, op, na)
        drag.res, drag.label, drag.lo, drag.hi = res, lbl, lo, hi
        grow_window(drag.E, lo, hi)
        write(drag.E, res)
      end
    end
  end

  if ImGui.IsItemDeactivated(ctx) and mine then
    if drag.E and not drag.cancelled then
      if math.abs(drag.a) > 1e-6 then
        commit(drag.E, op, drag.res, drag.label, drag.lo, drag.hi)
      else
        write(drag.E, drag.E.orig)
      end
    end
    drag = nil
  end

  -- draw (greyed out inside BeginDisabled: style alpha is lowered there)
  local k = ImGui.GetStyleVar(ctx, ImGui.StyleVar_Alpha) or 1
  local function fade(c)
    if k >= 1 then return c end
    return (c & ~0xFF) | math.floor((c & 0xFF) * k)
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  local cx = (x1 + x2) * 0.5
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, fade((hovered or active) and COL.bg_hov or COL.bg), 3)
  local a = (mine and drag and drag.E and not drag.cancelled) and drag.a or 0
  if a ~= 0 then
    local fx = cx + a * (x2 - x1) * 0.5
    ImGui.DrawList_AddRectFilled(dl, math.min(cx, fx), y1 + 3, math.max(cx, fx), y2 - 3, COL.fill, 2)
  end
  ImGui.DrawList_AddLine(dl, cx, y1 + 2, cx, y2 - 2, fade(COL.center), 1)
  ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, fade(COL.border), 3)
  local _, th = ImGui.CalcTextSize(ctx, label)
  ImGui.DrawList_AddText(dl, x1 + 8, y1 + (h - th) * 0.5, fade(COL.text), label)
  if a ~= 0 and drag.label then
    local vw = ImGui.CalcTextSize(ctx, drag.label)
    ImGui.DrawList_AddText(dl, x2 - vw - 8, y1 + (h - th) * 0.5, COL.value, drag.label)
  end
  if tip and hovered and not active then ImGui.SetItemTooltip(ctx, tip) end
end

---------------------------------------------------------------- panel
-- hardware-style switch left of a strip: all switch blocks share one width so the strips line up
local SW_W  = 120
local COL_W = 324   -- width of each of the 3 columns

local function switch(id, key, labels, tips)
  local n = #labels
  local bw = (SW_W - 2 * (n - 1)) / n
  for i, lb in ipairs(labels) do
    local on = (cfg[key] == i - 1)
    if on then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, COL.sw_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, COL.sw_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, COL.sw_txt)
    end
    if ImGui.Button(ctx, lb .. '##' .. id .. i, bw, 24) then cfg[key] = i - 1; save_cfg() end
    if on then ImGui.PopStyleColor(ctx, 3) end
    if tips and tips[i] then ImGui.SetItemTooltip(ctx, tips[i]) end
    ImGui.SameLine(ctx, 0, (i < n) and 2 or 6)
  end
end

local function no_switch()
  ImGui.Dummy(ctx, SW_W, 24)
  ImGui.SameLine(ctx, 0, 6)
end


local function panel()
  refresh_target()
  ImGui.SeparatorText(ctx, 'TARGET')
  -- source switch: lights what is edited; follows your last click, click here to force it
  for i, s in ipairs({ { 'env', 'ENVELOPE' }, { 'midi', 'MIDI EDITOR' } }) do
    local on = (src == s[1])
    if on then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, COL.sw_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, COL.sw_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, COL.sw_txt)
    end
    if ImGui.Button(ctx, s[2] .. '##src', SW_W, 24) and not drag then
      src, rebase, target_next = s[1], true, 0
    end
    if on then ImGui.PopStyleColor(ctx, 3) end
    ImGui.SameLine(ctx, 0, i == 1 and 2 or 8)
  end
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, 'follows your last click')
  ImGui.TextColored(ctx, target_ok and COL.ok or COL.err, target_txt)
  local isvel = target_midi and target_midi.kind == 'vel'   -- velocity: notes never move

  local rv
  if not ImGui.BeginTable(ctx, '##cols', 3, ImGui.TableFlags_BordersInnerV) then return end
  for c = 1, 3 do ImGui.TableSetupColumn(ctx, '##c' .. c, ImGui.TableColumnFlags_WidthFixed, COL_W) end

  -- column 1 ------------------------------------------------------------
  ImGui.TableNextColumn(ctx)
  ImGui.SeparatorText(ctx, 'TIME')
  if isvel then ImGui.BeginDisabled(ctx) end
  switch('st', 'stretch_side', { 'L', 'R' }, { 'Left edge moves, right edge stays.', 'Right edge moves, left edge stays.' })
  strip(cfg.stretch_side == 0 and 'stretchL' or 'stretchR', 'STRETCH', 'Squeeze/expand in time.')
  no_switch()
  strip('movet', 'MOVE', 'Shift all target points in time.')
  no_switch()
  strip('warpt', 'WARP', 'Bunch the points towards the start or end. Edges stay.')
  if isvel then ImGui.EndDisabled(ctx) end
  no_switch()
  strip('rotate', 'ROTATE', isvel and 'Shift the velocity pattern by whole notes; notes stay where they are.'
                               or 'Slide the pattern inside the area in steps of its own points; what falls off one end comes back at the other.')
  if isvel then ImGui.BeginDisabled(ctx) end
  no_switch()
  rv, cfg.snap = ImGui.Checkbox(ctx, 'Snap time to grid', cfg.snap)
  if rv then save_cfg() end

  ImGui.SeparatorText(ctx, 'SHAPE  (line between points)')
  no_switch()
  strip('bend', 'BEND', 'Curve the lines between the points (Bezier). Left/right = bend down/up.')
  local bw = (ImGui.GetContentRegionAvail(ctx) - 2 * 4) / 3
  for i = 0, 5 do
    if i % 3 ~= 0 then ImGui.SameLine(ctx, 0, 4) end
    if ImGui.Button(ctx, SHAPE_BTN[i] .. '##shape' .. i, bw, 0) then
      shape_pick = i
      one_shot('shape')
    end
  end
  if isvel then ImGui.EndDisabled(ctx) end

  -- column 2 ------------------------------------------------------------
  ImGui.TableNextColumn(ctx)
  ImGui.SeparatorText(ctx, 'VALUE')
  switch('ti', 'tilt_side', { 'L', 'R' }, { 'Left side moves, right side stays.', 'Right side moves, left side stays.' })
  strip(cfg.tilt_side == 0 and 'tiltL' or 'tiltR', 'TILT', 'Lift/lower one side. Uses the tilt curve.')
  no_switch()
  ImGui.SetNextItemWidth(ctx, 110)
  rv, cfg.curve = ImGui.Combo(ctx, '##curve', cfg.curve, 'Linear\0Slow start\0Slow end\0S-curve\0')
  if rv then save_cfg() end
  ImGui.SetItemTooltip(ctx, 'Tilt curve')
  ImGui.SameLine(ctx)
  if cfg.curve == 0 then ImGui.BeginDisabled(ctx) end
  ImGui.SetNextItemWidth(ctx, -1)
  rv, cfg.steep = ImGui.SliderDouble(ctx, '##steep', cfg.steep, 1, 5, 'Steepness %.1f')
  if rv and not ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) then cfg.steep = round_to(cfg.steep, 0.5) end
  if rv then save_cfg() end
  if cfg.curve == 0 then ImGui.EndDisabled(ctx) end
  switch('sc', 'scale_anchor', { 'LOW', 'MID', 'HIGH' },
         { 'Lowest point stays.', 'Middle stays: compress / expand.', 'Highest point stays.' })
  strip(({ [0] = 'scaleT', 'comp', 'scaleB' })[cfg.scale_anchor] or 'scaleT', 'SCALE', 'Smaller/bigger movement. Switch = what stays put.')
  no_switch()
  strip('movev', 'MOVE', 'Shift all values up/down.')
  no_switch()
  strip('warpv', 'WARP', 'Bend values towards the low or high end. Lowest/highest stay.')
  no_switch()
  strip('jitter', 'JITTER', 'Random variation per point. New pattern on every drag.')

  ImGui.SeparatorText(ctx, 'ONE CLICK')
  if ImGui.Button(ctx, 'FLIP VALUES') then one_shot('flip') end
  ImGui.SameLine(ctx)
  if isvel then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, 'REVERSE') then one_shot('reverse') end
  if isvel then ImGui.EndDisabled(ctx) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'UNDO') then reaper.Main_OnCommand(40029, 0) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'REDO') then reaper.Main_OnCommand(40030, 0) end

  -- column 3 ------------------------------------------------------------
  ImGui.TableNextColumn(ctx)
  ImGui.SeparatorText(ctx, 'POINTS')
  if isvel then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, 'ADD POINTS', SW_W, 0) then one_shot('addpts') end
  ImGui.SetItemTooltip(ctx, 'Fill the target with evenly spaced points on the current line.')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, -1)
  rv, cfg.spacing = ImGui.Combo(ctx, '##spacing', cfg.spacing, 'Every grid step\0Every 1/4\0Every 1/8\0Every 1/16\0Every 1/32\0')
  if rv then save_cfg() end
  if ImGui.Button(ctx, 'REDUCE', SW_W, 0) then one_shot('reduce') end
  ImGui.SetItemTooltip(ctx, 'Remove points the line does not need (after freehand drawing or a recorded knob).')
  if isvel then ImGui.EndDisabled(ctx) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'DESELECT', -1, 0) then deselect_all() end
  ImGui.SetItemTooltip(ctx, src == 'midi' and 'Unselect all events in the MIDI take.'
                                           or 'Unselect all envelope points on this track (incl. automation items).')

  ImGui.SeparatorText(ctx, 'GENERATE')
  if ImGui.Button(ctx, 'GENERATE', SW_W, 0) then one_shot('gen') end
  ImGui.SetItemTooltip(ctx, 'Replace the target with the chosen shape.')
  ImGui.SameLine(ctx, 0, 4)
  ImGui.SetNextItemWidth(ctx, -1)
  rv, cfg.gen = ImGui.Combo(ctx, '##gen', cfg.gen, GEN_COMBO)
  if rv then save_cfg() end
  local isrnd, oneshot = cfg.gen >= 9, cfg.gen <= 3
  if oneshot or isrnd then ImGui.BeginDisabled(ctx) end
  ImGui.SetNextItemWidth(ctx, -1)
  rv, cfg.cycles = ImGui.SliderInt(ctx, '##cycles', cfg.cycles, 1, 32, isrnd and 'Steps = POINTS spacing' or 'Cycles %d')
  if rv then save_cfg() end
  if oneshot or isrnd then ImGui.EndDisabled(ctx) end
  local hw = (ImGui.GetContentRegionAvail(ctx) - 4) / 2
  ImGui.SetNextItemWidth(ctx, hw)
  rv, cfg.lo = ImGui.SliderDouble(ctx, '##lo', cfg.lo, 0, 100, level_fmt('Low', cfg.lo))
  if rv then cfg.lo = detent_level(cfg.lo) end
  if rv then save_cfg() end
  ImGui.SetItemTooltip(ctx, 'Lowest value of the generated shape.')
  ImGui.SameLine(ctx, 0, 4)
  ImGui.SetNextItemWidth(ctx, hw)
  rv, cfg.hi = ImGui.SliderDouble(ctx, '##hi', cfg.hi, 0, 100, level_fmt('High', cfg.hi))
  if rv then cfg.hi = detent_level(cfg.hi) end
  if rv then save_cfg() end
  ImGui.SetItemTooltip(ctx, 'Highest value of the generated shape.')

  ImGui.SeparatorText(ctx, 'VOLUME LANES')
  local novol = not target_vol
  if novol then ImGui.BeginDisabled(ctx) end
  switch('vm', 'vol_max', { '0 dB', '+6 dB' }, { 'Volume lanes top out at 0 dB.', 'Volume lanes top out at +6 dB.' })
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, 'Top of the lane')
  if novol then ImGui.EndDisabled(ctx) end

  ImGui.EndTable(ctx)
  ImGui.Separator(ctx)
  if status ~= '' then ImGui.TextColored(ctx, status_err and COL.err or COL.value, status) end
  ImGui.TextDisabled(ctx, 'Drag = live  |  Esc = cancel  |  Shift = fine')
end

local function loop()
  -- window always fits its content (3 columns side by side)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, COL.win)   -- opaque panel
  local visible, open = ImGui.Begin(ctx, SCRIPT .. ' ' .. VERSION .. '###NH4XEnvShaper', true, ImGui.WindowFlags_AlwaysAutoResize)
  ImGui.PopStyleColor(ctx)
  if visible then
    panel()
    ImGui.End(ctx)
  end
  if open then
    reaper.defer(loop)
  else
    cancel_drag()
  end
end

-- toggle action: running it again closes the panel; the action shows ON while the panel is open
if reaper.set_action_options then pcall(reaper.set_action_options, 1 | 4) end
reaper.atexit(function()
  cancel_drag()
  if reaper.set_action_options then pcall(reaper.set_action_options, 8) end
end)
reaper.defer(loop)
