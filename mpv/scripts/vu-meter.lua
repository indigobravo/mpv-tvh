-- vu-meter.lua
-- VU meter window: a pair of backlit analogue meters on the same
-- brushed-black front as the faceplates. Runs in its own media-less mpv
-- window (control socket /tmp/mpv-vu-<kind>), opened and closed by the VU
-- METER key of the radio or YouTube faceplate. The player (player-state.lua)
-- measures its audio with an astats filter and writes the levels to
-- /tmp/mpv-<kind>.vu about 30 times a second, already delayed to line up
-- with what you hear; this window reads them and moves the needles (quick
-- to rise, slower to fall). It closes when turned off or when the player
-- quits. Drag the window to move it.
--
-- Broadcast audio is heavily compressed and stations differ in loudness, so
-- by default the meter sets its own 0 VU: it follows the average level over
-- the last several seconds and keeps that at about -3 VU, so the needles
-- swing with the music's dynamics. Script-opt vu-ref fixes 0 VU at a level
-- in dBFS (RMS) instead, e.g. vu-ref=-16.

local mp = require 'mp'

local SOURCE = (mp.get_property("input-ipc-server") or ""):match("/mpv%-vu%-(%a+)$")
if not SOURCE then return end

local VU_FILE  = "/tmp/mpv-" .. SOURCE .. ".vu"
local VU_ALIVE = "/tmp/mpv-" .. SOURCE .. ".vu.alive"
local FIXED_REF = tonumber(mp.get_opt("vu-ref") or "")   -- dBFS RMS that reads 0 VU, or auto
local AVG_TAU  = 6             -- seconds: auto level follows the average this slowly
local AVG_AT   = -3            -- auto level: where the average reads (VU)
local RISE     = 0.03          -- needle time constants (s): quick up,
local FALL     = 0.28          -- slower down
local PEAK_VU  = 2.5           -- PEAK lamp: instant level at or above this (VU)

local DISPLAYS = {             -- scale colour follows the radio's display colour
    blue  = { "#9FE8FF", "#4E8FA6" },
    red   = { "#FF5A47", "#9A3326" },
    green = { "#7DFFB0", "#3E9A66" },
    amber = { "#FFB347", "#A06A22" },
}
local C = {
    plate = "#0E0E10", plate_top = "#1C1C20", plate_lo = "#030304", streak = "#FFFFFF",
    silk = "#C9C9CE", silk_dim = "#707078", bezel = "#1A1A1D", window = "#040506",
    hood = "#0B0B0D", over = "#FF4A3D", needle = "#F4F0E6", led_off = "#2A1210",
}
local FONT = "Helvetica Neue"

---------------------------------------------------------------------------
-- Drawing (ASS), on a 1600x900 grid scaled to fit the window
---------------------------------------------------------------------------

local GW, GH = 1600, 900
local S, OX, OY = 1, 0, 0
local function X(v) return OX + v * S end
local function Y(v) return OY + v * S end
local function N(v) return v * S end
local function f1(n) return string.format("%.1f", n) end

local function col(hex)
    local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
    return string.format("&H%s%s%s&", b, g, r)
end

local function rect_path(x, y, w, h)
    x, y, w, h = X(x), Y(y), N(w), N(h)
    return string.format("m %s %s l %s %s l %s %s l %s %s ",
        f1(x), f1(y), f1(x + w), f1(y), f1(x + w), f1(y + h), f1(x), f1(y + h))
end

local function rrect_path(x, y, w, h, r)
    x, y, w, h, r = X(x), Y(y), N(w), N(h), N(r)
    local k = r * 0.4477
    local x2, y2 = x + w, y + h
    return table.concat({
        "m", f1(x + r), f1(y), "l", f1(x2 - r), f1(y),
        "b", f1(x2 - k), f1(y), f1(x2), f1(y + k), f1(x2), f1(y + r),
        "l", f1(x2), f1(y2 - r),
        "b", f1(x2), f1(y2 - k), f1(x2 - k), f1(y2), f1(x2 - r), f1(y2),
        "l", f1(x + r), f1(y2),
        "b", f1(x + k), f1(y2), f1(x), f1(y2 - k), f1(x), f1(y2 - r),
        "l", f1(x), f1(y + r),
        "b", f1(x), f1(y + k), f1(x + k), f1(y), f1(x + r), f1(y),
    }, " ") .. " "
end

local function circle_path(cx, cy, r) return rrect_path(cx - r, cy - r, 2 * r, 2 * r, r) end

local function poly_path(pts)
    local p = { "m", f1(X(pts[1])), f1(Y(pts[2])) }
    for i = 3, #pts, 2 do p[#p + 1] = "l"; p[#p + 1] = f1(X(pts[i])); p[#p + 1] = f1(Y(pts[i + 1])) end
    return table.concat(p, " ") .. " "
end

-- Filled shape; a = transparency 0 (opaque) .. 255; clip = {x, y, w, h}
local function shape(path, color, a, blur, clip)
    local c = clip and string.format("\\clip(%s,%s,%s,%s)", f1(X(clip[1])), f1(Y(clip[2])),
        f1(X(clip[1] + clip[3])), f1(Y(clip[2] + clip[4]))) or ""
    return string.format("{\\an7\\pos(0,0)%s\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s\\p1}%s{\\p0}",
        c, col(color), a or 0, f1(N(blur or 0)), path)
end

local function text(x, y, align, size, color, s, bold, spacing, a, blur)
    s = (s or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
    return string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\fsp%s\\b%d\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s}%s",
        align, f1(X(x)), f1(Y(y)), FONT, f1(N(size)), f1(N(spacing or 0)), bold and 1 or 0,
        col(color), a or 0, f1(N(blur or 0)), s)
end

---------------------------------------------------------------------------
-- Meter geometry. The needle pivots below the scale, hidden by the hood at
-- the bottom of the face. Scale positions follow signal voltage, so the
-- dB marks crowd towards the top end, as on a real VU meter.
---------------------------------------------------------------------------

local SWING = 42                                  -- degrees either side of upright
local AMP_LO, AMP_HI = 10 ^ (-20 / 20), 10 ^ (3 / 20)

local function angle_of_amp(amp)
    local a = (amp - AMP_LO) / (AMP_HI - AMP_LO)
    return math.max(-SWING - 4, math.min(SWING + 4, -SWING + 2 * SWING * a))
end
local function angle_of_vu(db) return angle_of_amp(10 ^ (db / 20)) end

local METERS = {}
for i, label in ipairs({ "LEFT", "RIGHT" }) do
    local face = { x = i == 1 and 90 or 830, y = 220, w = 680, h = 540 }
    local hood = 78
    METERS[i] = {
        label = label, face = face, hood = hood,
        px = face.x + face.w / 2, py = face.y + face.h + 40,   -- needle pivot
        r = 420,                                              -- scale radius
        clip = { face.x, face.y, face.w, face.h - hood },
        amp = 0, peak_until = 0,
    }
end

local function polar(m, deg, r)
    local t = math.rad(deg)
    return m.px + r * math.sin(t), m.py - r * math.cos(t)
end

-- Band along the scale between two angles
local function arc_path(m, a1, a2, r1, r2)
    local outer, inner = {}, {}
    local steps = math.max(2, math.ceil(math.abs(a2 - a1) / 2))
    for k = 0, steps do
        local a = a1 + (a2 - a1) * k / steps
        local x, y = polar(m, a, r2); outer[#outer + 1] = x; outer[#outer + 1] = y
        x, y = polar(m, a, r1); table.insert(inner, 1, y); table.insert(inner, 1, x)
    end
    for k = 1, #inner do outer[#outer + 1] = inner[k] end
    return poly_path(outer)
end

local function tick_path(m, deg, r1, r2, wdeg)
    local x1, y1 = polar(m, deg - wdeg, r1)
    local x2, y2 = polar(m, deg - wdeg, r2)
    local x3, y3 = polar(m, deg + wdeg, r2)
    local x4, y4 = polar(m, deg + wdeg, r1)
    return poly_path({ x1, y1, x2, y2, x3, y3, x4, y4 })
end

---------------------------------------------------------------------------
-- Static layer: front panel, bezels, faces, scales
---------------------------------------------------------------------------

local overlay = mp.create_osd_overlay("ass-events")
local static = { w = 0, h = 0, theme = nil, data = "" }
local state = { theme = "blue", open = true, t = os.time(), l = -90, r = -90, pl = -90, pr = -90, title = "" }
local avg_db = nil             -- running average level, for the auto 0 VU

local MARKS = { { -20, "20" }, { -10, "10" }, { -7, "7" }, { -5, "5" }, { -3, "3" }, { -2, "2" },
                { -1, "1" }, { 0, "0" }, { 1, "1" }, { 2, "2" }, { 3, "3" } }
local MINOR = { -15, -8.5, -6, -4, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5 }

local function build_static(w, h)
    local FL = DISPLAYS[state.theme] or DISPLAYS.blue
    local ev = {}

    -- Front panel
    ev[#ev + 1] = shape(rect_path(0, 0, GW, GH), C.plate_lo)
    ev[#ev + 1] = shape(rrect_path(10, 10, GW - 20, GH - 20, 14), C.plate_top)
    ev[#ev + 1] = shape(rrect_path(10, 14, GW - 20, GH - 24, 14), C.plate)
    local brush = {}
    for i = 0, math.floor((GH - 50) / 5) do
        brush[#brush + 1] = rect_path(24, 24 + i * 5 + (i * 7 % 3), GW - 48, 1)
    end
    ev[#ev + 1] = shape(table.concat(brush), C.streak, 247)

    -- Badge
    ev[#ev + 1] = text(90, 92, 4, 44, C.silk, "mpv-tvh", true, 3)
    ev[#ev + 1] = text(92, 146, 4, 22, C.silk, "VU-252", true, 3)
    ev[#ev + 1] = text(1510, 146, 6, 16, C.silk_dim, "STEREO LEVEL METER", false, 5)

    for _, m in ipairs(METERS) do
        local f = m.face
        -- Bezel and glass
        ev[#ev + 1] = shape(rrect_path(f.x - 16, f.y - 16, f.w + 32, f.h + 32, 20), C.bezel)
        ev[#ev + 1] = shape(rrect_path(f.x - 16, f.y - 16, f.w + 32, 6, 3), "#000000", 60)
        ev[#ev + 1] = shape(rrect_path(f.x, f.y, f.w, f.h, 8), C.window)
        -- Backlight glow behind the scale
        ev[#ev + 1] = shape(circle_path(m.px, m.py - m.r * 0.8, m.r * 0.75), FL[1], 236, 90,
            { f.x, f.y, f.w, f.h })

        -- Scale: band up to 0 VU in the display colour, red above
        local a0 = angle_of_vu(0)
        ev[#ev + 1] = shape(arc_path(m, -SWING, a0, m.r, m.r + 5), FL[1], 120, 6)
        ev[#ev + 1] = shape(arc_path(m, -SWING, a0, m.r, m.r + 5), FL[1])
        ev[#ev + 1] = shape(arc_path(m, a0, SWING, m.r, m.r + 14), C.over, 120, 6)
        ev[#ev + 1] = shape(arc_path(m, a0, SWING, m.r, m.r + 14), C.over)
        local ticks, red = {}, {}
        for _, mk in ipairs(MARKS) do
            local a = angle_of_vu(mk[1])
            local path = tick_path(m, a, m.r - 2, m.r + 34, 0.45)
            if mk[1] > 0 then red[#red + 1] = path else ticks[#ticks + 1] = path end
            local tx, ty = polar(m, a, m.r + 62)
            ev[#ev + 1] = text(tx, ty, 5, mk[1] == 0 and 34 or 28, mk[1] > 0 and C.over or FL[1], mk[2], true)
        end
        for _, db in ipairs(MINOR) do
            local path = tick_path(m, angle_of_vu(db), m.r - 2, m.r + 18, 0.3)
            if db > 0 then red[#red + 1] = path else ticks[#ticks + 1] = path end
        end
        ev[#ev + 1] = shape(table.concat(ticks), FL[1])
        ev[#ev + 1] = shape(table.concat(red), C.over)
        local lx, ly = polar(m, -SWING + 3, m.r - 44)
        ev[#ev + 1] = text(lx, ly, 5, 40, FL[1], "−", true)
        local rx, ry = polar(m, SWING - 3, m.r - 44)
        ev[#ev + 1] = text(rx, ry, 5, 40, C.over, "+", true)
        ev[#ev + 1] = text(m.px, f.y + f.h - m.hood - 60, 2, 64, FL[1], "VU", true, 4, 140, 6)
        ev[#ev + 1] = text(m.px, f.y + f.h - m.hood - 60, 2, 64, FL[1], "VU", true, 4)

        -- Hood over the pivot, with the channel name
        ev[#ev + 1] = shape(rect_path(f.x, f.y + f.h - m.hood, f.w, m.hood), C.hood, 0, 0, { f.x, f.y, f.w, f.h })
        ev[#ev + 1] = shape(rect_path(f.x, f.y + f.h - m.hood, f.w, 2), C.plate_top)
        ev[#ev + 1] = text(m.px, f.y + f.h - m.hood / 2, 5, 22, C.silk, m.label, false, 8)

        -- Peak lamp legend
        ev[#ev + 1] = text(f.x + f.w - 44, f.y - 46, 6, 15, C.silk_dim, "PEAK", false, 4)
    end

    static.w, static.h, static.theme, static.data = w, h, state.theme, table.concat(ev, "\n")
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function needle(ev, m, deg)
    local x1, y1 = polar(m, deg - 0.35, 0)
    local x2, y2 = polar(m, deg + 0.35, 0)
    local tx, ty = polar(m, deg, m.r + 40)
    local tip_l, tip_ly = polar(m, deg - 0.18, m.r + 40)
    local tip_r, tip_ry = polar(m, deg + 0.18, m.r + 40)
    local path = poly_path({ x1 - 2, y1, tip_l, tip_ly, tip_r, tip_ry, x2 + 2, y2 })
    ev[#ev + 1] = shape(path, "#000000", 120, 6, { m.clip[1] + 8, m.clip[2] + 10, m.clip[3], m.clip[4] })
    ev[#ev + 1] = shape(path, C.needle, 0, 0.6, m.clip)
end

local last_t = mp.get_time()

local function frame()
    local w, h = mp.get_osd_size()
    if not w or w == 0 or h == 0 then return end
    if w ~= static.w or h ~= static.h or state.theme ~= static.theme then
        overlay.res_x, overlay.res_y = w, h
        S = math.min(w / GW, h / GH)
        OX, OY = (w - GW * S) / 2, (h - GH * S) / 2
        build_static(w, h)
    end

    local now = mp.get_time()
    local dt = math.min(0.2, now - last_t)
    last_t = now

    -- 0 VU: fixed, or following the average level of what's playing
    local loud = math.max(state.l, state.r)
    if loud > -60 then
        avg_db = avg_db and avg_db + (loud - avg_db) * (1 - math.exp(-dt / AVG_TAU)) or loud
    end
    local ref = FIXED_REF or math.max(-36, math.min(-4, (avg_db or -16) - AVG_AT))

    local ev = { static.data }
    for i, m in ipairs(METERS) do
        local vu = (i == 1 and state.l or state.r) - ref
        local target = 10 ^ (vu / 20)
        local k = 1 - math.exp(-dt / (target > m.amp and RISE or FALL))
        m.amp = m.amp + (target - m.amp) * k
        if vu >= PEAK_VU then m.peak_until = now + 0.4 end
        needle(ev, m, angle_of_amp(m.amp))

        local on = now < m.peak_until
        local lx, ly = m.face.x + m.face.w - 24, m.face.y - 46
        if on then ev[#ev + 1] = shape(circle_path(lx, ly, 10), C.over, 120, 10) end
        ev[#ev + 1] = shape(circle_path(lx, ly, 6), on and C.over or C.led_off)
    end
    if state.title ~= "" then
        ev[#ev + 1] = text(GW / 2, 146, 5, 22, C.silk, state.title:upper(), false, 4)
    end
    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

---------------------------------------------------------------------------
-- Levels from the radio; heartbeat back to it
---------------------------------------------------------------------------

local function read_levels()
    local f = io.open(VU_FILE, "r")
    if not f then return end
    local line, title = f:read("*l"), f:read("*l")
    f:close()
    local t, open, theme, l, r, pl, pr = (line or ""):match("^(%d+) (%d) (%a+) (%S+) (%S+) (%S+) (%S+)")
    if not t then return end
    state.t, state.open, state.theme = tonumber(t), open == "1", theme
    state.l, state.r, state.pl, state.pr = tonumber(l), tonumber(r), tonumber(pl), tonumber(pr)
    state.title = title or ""
end

mp.add_periodic_timer(1 / 30, function()
    read_levels()
    if not state.open or os.time() - state.t > 5 then mp.command("quit"); return end   -- radio off or gone
    frame()
end)

mp.add_periodic_timer(1, function()
    local f = io.open(VU_ALIVE, "w")
    if f then f:write(os.time(), "\n"); f:close() end
end)

mp.add_forced_key_binding("MBTN_LEFT", "vu-drag", function(e)
    if e.event == "down" then pcall(mp.commandv, "begin-vo-dragging") end
end, { complex = true })

mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
mp.commandv("keybind", "MBTN_LEFT_DBL", "ignore")              -- not full screen
