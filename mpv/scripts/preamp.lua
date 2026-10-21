-- preamp.lua
-- The PR-252 control amplifier: a media-less mpv window (control socket
-- /tmp/mpv-preamp, started by `preamp`) drawn like the other faceplates,
-- that chooses which source you hear.
--
--   Switching it on starts the TV and the tuner, with TV chosen (or the
--   source whose pad key started it); the others start when chosen.
--   INPUT keys TV, TUNER, NETWORK, CD and VIDEO choose the source. The sources keep
--   running: the one chosen plays at full volume and the others at none, so
--   switching back finds live TV and radio where they are now, and the CD and
--   YouTube where they've got to. A source that isn't running is started;
--   a source started any other way becomes the one chosen.
--
--   The display shows the sources running and the one chosen, the source's
--   name, the Mac's volume, what the source is playing, level bars and the
--   sound device (OUT). The VOLUME knob (scroll over it) and MUTE set the
--   Mac's volume; Hammerspoon writes the volume and device to
--   /tmp/mpv-tvh.audio and tells the preamp (script-message preamp-audio).
--   DIM darkens the display and stops the level bars. SCROLL sets when
--   long text scrolls: AUTO (only while the preamp is active), OFF, ON. COLOUR follows the source's display colour (AUTO) or picks one. MONITOR
--   opens and closes the chosen source's windows: PICTURE (TV, YouTube, video: the
--   picture, or just the sound), VU METER, the CD's PLAYLIST, the CD's and
--   video's LIBRARY, and the TV's GUIDE (in LIBRARY's place). Windows in the secondary picture slot (under the TV window)
--   stay open, stacked; choosing a source brings its ones to the front.
--   STACK (on when the preamp's switched on) moves the faceplates up under the preamp in two rows: the TV
--   (the primary) always first, then the others on top of each other, the
--   chosen one in front; press
--   it again to put them back. Hammerspoon moves the windows (the
--   hammerspoon://tvh-view URL). REC OUT (off, TV, TUNER, NET) picks what
--   the RC-252 recorder records (recorder.lua), whatever you're listening
--   to; it's written to /tmp/mpv-preamp.rec. POWER turns everything off.
--
-- script-message preamp-select <tv|tuner|net|cd|vid> chooses a source (the pad's
-- keys, via Hammerspoon). The choice is written to /tmp/mpv-preamp.input and
-- saved, with the display settings, in mpv's state folder.

local mp = require 'mp'
local utils = require 'mp.utils'

if not (mp.get_property("input-ipc-server") or ""):match("/mpv%-preamp$") then return end

local SOURCES = {
    { id = "tv",    kind = "tv",      label = "TV",    caption = "TV",      name = "TELEVISION",
      start = "tv --default", cmd = "tv",      face = "panel-tv",
      windows = { video = true, vu = true, library = true } },          -- library: the guide
    { id = "tuner", kind = "radio",   label = "TUNER", caption = "TUNER",   name = "TUNER",
      start = "radio --default", cmd = "radio",   face = "radio",
      windows = { vu = true, library = true } },                        -- library: the guide
    { id = "net",   kind = "youtube", label = "NET",   caption = "NETWORK", name = "NETWORK",
      start = "youtube --default", cmd = "youtube", face = "panel-youtube",
      windows = { video = true, vu = true, list = true } },
    { id = "cd",    kind = "music",   label = "CD",    caption = "CD",      name = "COMPACT DISC",
      start = "music", cmd = "music",             face = "panel-music",
      windows = { vu = true, list = true, library = true } },
    { id = "vid",   kind = "video",   label = "VIDEO", caption = "VIDEO",   name = "VIDEO",
      start = "video", cmd = "video",             face = "panel-video",
      windows = { video = true, vu = true, library = true } },
}
-- MONITOR buttons: the chosen source's windows, opened by its faceplate
local MONITOR = {
    { id = "video",   caption = "PICTURE",  icon = "video" },
    { id = "vu",      caption = "VU METER", icon = "vu" },
    { id = "list",    caption = "PLAYLIST", icon = "list" },
    { id = "library", caption = "LIBRARY",  icon = "library" },
}
local BY_ID = {}
for _, s in ipairs(SOURCES) do BY_ID[s.id] = s end

local AUDIO_FILE = "/tmp/mpv-tvh.audio"            -- "volume muted device name", from Hammerspoon
local INPUT_FILE = "/tmp/mpv-preamp.input"
local PREFS_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-preamp-prefs" })
local FULL = 100                                    -- the chosen source's volume

local DISPLAYS = {
    blue  = { "#9FE8FF", "#4E8FA6", "#0B171B" },
    red   = { "#FF5A47", "#9A3326", "#1C0C0A" },
    green = { "#7DFFB0", "#3E9A66", "#0A1912" },
    amber = { "#FFB347", "#A06A22", "#1C1409" },
}
local CYCLE = { "auto", "blue", "red", "green", "amber" }
local C = {
    plate = "#0E0E10", plate_top = "#1C1C20", plate_lo = "#030304", streak = "#FFFFFF",
    silk = "#C9C9CE", silk_dim = "#707078", window = "#030506", bezel = "#1A1A1D",
    button = "#18181B", button_rim = "#3A3A40", button_dn = "#0B0B0D",
    led_on = "#3DDC84", led_dim = "#1E4A30", led_off = "#1B1D1C",
    knob = "#1E1E22", knob_rim = "#34343A", knob_face = "#16161A",
}
local FONT = "Helvetica Neue"
local DIM_ALPHA = 77

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local prefs = {}
do
    local f = io.open(PREFS_FILE, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^(%w+)=(%w+)$")
            if k then prefs[k] = v end
        end
        f:close()
    end
end
-- Switching on: TV, unless started for a particular source (a pad key)
local input      = BY_ID[mp.get_opt("preamp-input") or ""] and mp.get_opt("preamp-input") or "tv"
local colour     = prefs.colour or "auto"
local show_clock = prefs.clock ~= "off"
local dim_manual = prefs.dim == "on"
local scroll_mode = ({ auto = 1, off = 1, on = 1 })[prefs.scroll or ""] and prefs.scroll or "auto"
local stacked    = true                           -- STACK: the compact view (on at switch-on)
local REC_CYCLE  = { "off", "tv", "tuner", "net" }  -- REC OUT: what the recorder records
local rec_out    = (prefs.rec == "tv" or prefs.rec == "tuner" or prefs.rec == "net") and prefs.rec or "off"
local STACK_AT   = mp.get_opt("preamp-stack") or ""  -- where: the TV window's --geometry

local function save_prefs()
    local f = io.open(PREFS_FILE, "w")
    if not f then return end
    f:write("input=", input, "\n", "colour=", colour, "\n", "clock=", show_clock and "on" or "off", "\n",
            "dim=", dim_manual and "on" or "off", "\n", "view=", stacked and "stack" or "full", "\n",
            "scroll=", scroll_mode, "\n",
            "rec=", rec_out, "\n")
    f:close()
    f = io.open(INPUT_FILE, "w")
    if f then f:write(input, "\n"); f:close() end
    f = io.open("/tmp/mpv-preamp.rec", "w")
    if f then f:write(rec_out, "\n"); f:close() end
end

---------------------------------------------------------------------------
-- Drawing helpers (ASS): a grid 240 units high, GW wide, scaled by S
---------------------------------------------------------------------------

local GH = 480                         -- twice a faceplate's height
local GW, S = 2400, 1
local function N(v) return v * S end
local function f1(n) return string.format("%.1f", n) end

local function col(hex)
    local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
    return string.format("&H%s%s%s&", b, g, r)
end

local function rect_path(x, y, w, h)
    x, y, w, h = N(x), N(y), N(w), N(h)
    return string.format("m %s %s l %s %s l %s %s l %s %s ",
        f1(x), f1(y), f1(x + w), f1(y), f1(x + w), f1(y + h), f1(x), f1(y + h))
end

local function rrect_path(x, y, w, h, r)
    x, y, w, h, r = N(x), N(y), N(w), N(h), N(r)
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
    local p = { "m", f1(N(pts[1])), f1(N(pts[2])) }
    for i = 3, #pts, 2 do p[#p + 1] = "l"; p[#p + 1] = f1(N(pts[i])); p[#p + 1] = f1(N(pts[i + 1])) end
    return table.concat(p, " ") .. " "
end

local function line_path(x1, y1, x2, y2, t)
    local dx, dy = x2 - x1, y2 - y1
    local l = math.sqrt(dx * dx + dy * dy)
    local nx, ny = -dy / l * t / 2, dx / l * t / 2
    return poly_path({ x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny })
end

-- Engraved symbols for the transport keys, centred on (cx, cy), size s
local function icon_path(kind, cx, cy, s)
    local h = s / 2
    if kind == "prev" then
        return poly_path({ cx, cy - h, cx, cy + h, cx - 0.8 * s, cy })
            .. poly_path({ cx + 0.8 * s, cy - h, cx + 0.8 * s, cy + h, cx, cy })
    elseif kind == "next" then
        return poly_path({ cx, cy - h, cx + 0.8 * s, cy, cx, cy + h })
            .. poly_path({ cx - 0.8 * s, cy - h, cx, cy, cx - 0.8 * s, cy + h })
    elseif kind == "playpause" then
        return poly_path({ cx - 0.95 * s, cy - h, cx - 0.15 * s, cy, cx - 0.95 * s, cy + h })
            .. rect_path(cx + 0.12 * s, cy - h, 0.26 * s, s)
            .. rect_path(cx + 0.58 * s, cy - h, 0.26 * s, s)
    elseif kind == "mute" then
        return rect_path(cx - 0.95 * s, cy - 0.2 * s, 0.3 * s, 0.4 * s)
            .. poly_path({ cx - 0.65 * s, cy - 0.2 * s, cx - 0.2 * s, cy - h, cx - 0.2 * s, cy + h, cx - 0.65 * s, cy + 0.2 * s })
            .. line_path(cx + 0.12 * s, cy - 0.28 * s, cx + 0.68 * s, cy + 0.28 * s, 0.13 * s)
            .. line_path(cx + 0.12 * s, cy + 0.28 * s, cx + 0.68 * s, cy - 0.28 * s, 0.13 * s)
    elseif kind == "vu" then                             -- meter scale and needle
        local p, r, t = {}, 0.95 * s, 0.13 * s
        local oy = cy + 0.5 * s
        for k = 0, 5 do
            local a1, a2 = math.rad(-60 + k * 24), math.rad(-60 + (k + 1) * 24)
            if k < 5 then
                p[#p + 1] = line_path(cx + r * math.sin(a1), oy - r * math.cos(a1),
                                      cx + r * math.sin(a2), oy - r * math.cos(a2), t)
            end
        end
        local a = math.rad(25)
        p[#p + 1] = line_path(cx, oy, cx + 1.05 * r * math.sin(a), oy - 1.05 * r * math.cos(a), t)
        return table.concat(p)
    elseif kind == "stop" then                           -- square
        return rect_path(cx - 0.55 * s, cy - 0.55 * s, 1.1 * s, 1.1 * s)
    elseif kind == "list" then                           -- lines of a list
        local t = 0.14 * s
        return rect_path(cx - 0.9 * s, cy - 0.55 * s, 1.8 * s, t) .. rect_path(cx - 0.9 * s, cy - t / 2, 1.8 * s, t)
            .. rect_path(cx - 0.9 * s, cy + 0.55 * s - t, 1.2 * s, t)
    elseif kind == "guide" then                          -- a programme grid
        local t, g = 0.22 * s, 0.1 * s
        local x0, x1 = cx - 0.95 * s, cx + 0.95 * s
        return rect_path(x0, cy - 0.62 * s, 0.7 * s, t) .. rect_path(x0 + 0.7 * s + g, cy - 0.62 * s, x1 - x0 - 0.7 * s - g, t)
            .. rect_path(x0, cy - t / 2, 1.15 * s, t) .. rect_path(x0 + 1.15 * s + g, cy - t / 2, x1 - x0 - 1.15 * s - g, t)
            .. rect_path(x0, cy + 0.62 * s - t, 0.45 * s, t) .. rect_path(x0 + 0.45 * s + g, cy + 0.62 * s - t, x1 - x0 - 0.45 * s - g, t)
    elseif kind == "library" then                        -- records on a shelf
        local t = 0.16 * s
        return rect_path(cx - 0.85 * s, cy - h, t, s) .. rect_path(cx - 0.5 * s, cy - h, t, s)
            .. rect_path(cx - 0.15 * s, cy - h, t, s)
            .. poly_path({ cx + 0.25 * s, cy - 0.42 * s, cx + 0.4 * s, cy - 0.48 * s,
                           cx + 0.85 * s, cy + 0.44 * s, cx + 0.7 * s, cy + 0.5 * s })
            .. rect_path(cx - 0.95 * s, cy + h + 0.08 * s, 1.9 * s, 0.1 * s)
    elseif kind == "video" then                          -- screen with a play triangle
        local w, hh, t = 1.0 * s, 0.68 * s, 0.12 * s
        return rect_path(cx - w, cy - hh, 2 * w, t) .. rect_path(cx - w, cy + hh - t, 2 * w, t)
            .. rect_path(cx - w, cy - hh, t, 2 * hh) .. rect_path(cx + w - t, cy - hh, t, 2 * hh)
            .. poly_path({ cx - 0.25 * s, cy - 0.32 * s, cx + 0.35 * s, cy, cx - 0.25 * s, cy + 0.32 * s })
    elseif kind == "full" then                           -- four corner brackets
        local a, t, l = 0.75 * s, 0.13 * s, 0.4 * s
        local p = {}
        local function box(x1, y1, x2, y2)
            p[#p + 1] = rect_path(math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1), math.abs(y2 - y1))
        end
        for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            local x, y = cx + c[1] * a, cy + c[2] * a
            box(x, y, x - c[1] * l, y - c[2] * t)
            box(x, y, x - c[1] * t, y - c[2] * l)
        end
        return table.concat(p)
    end
    return ""
end

local function shape(path, color, a, blur)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s\\p1}%s{\\p0}",
        col(color), a or 0, f1(N(blur or 0)), path)
end

local function esc(s)
    return ((s or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", " "))
end

local function text(x, y, align, size, color, s, bold, spacing, blur)
    return string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\fsp%s\\b%d\\bord0\\shad0\\1c%s\\blur%s}%s",
        align, f1(N(x)), f1(N(y)), FONT, f1(N(size)), f1(N(spacing or 0)),
        bold and 1 or 0, col(color), f1(N(blur or 0)), esc(s))
end

---------------------------------------------------------------------------
-- 5x7 dot-matrix font (as faceplate.lua)
---------------------------------------------------------------------------

local GLYPHS = {
    A = "01110 10001 10001 11111 10001 10001 10001", B = "11110 10001 10001 11110 10001 10001 11110",
    C = "01110 10001 10000 10000 10000 10001 01110", D = "11100 10010 10001 10001 10001 10010 11100",
    E = "11111 10000 10000 11110 10000 10000 11111", F = "11111 10000 10000 11110 10000 10000 10000",
    G = "01110 10001 10000 10111 10001 10001 01111", H = "10001 10001 10001 11111 10001 10001 10001",
    I = "01110 00100 00100 00100 00100 00100 01110", J = "00111 00010 00010 00010 00010 10010 01100",
    K = "10001 10010 10100 11000 10100 10010 10001", L = "10000 10000 10000 10000 10000 10000 11111",
    M = "10001 11011 10101 10101 10001 10001 10001", N = "10001 10001 11001 10101 10011 10001 10001",
    O = "01110 10001 10001 10001 10001 10001 01110", P = "11110 10001 10001 11110 10000 10000 10000",
    Q = "01110 10001 10001 10001 10101 10010 01101", R = "11110 10001 10001 11110 10100 10010 10001",
    S = "01111 10000 10000 01110 00001 00001 11110", T = "11111 00100 00100 00100 00100 00100 00100",
    U = "10001 10001 10001 10001 10001 10001 01110", V = "10001 10001 10001 10001 10001 01010 00100",
    W = "10001 10001 10001 10101 10101 10101 01010", X = "10001 10001 01010 00100 01010 10001 10001",
    Y = "10001 10001 10001 01010 00100 00100 00100", Z = "11111 00001 00010 00100 01000 10000 11111",
    ["0"] = "01110 10001 10011 10101 11001 10001 01110", ["1"] = "00100 01100 00100 00100 00100 00100 01110",
    ["2"] = "01110 10001 00001 00010 00100 01000 11111", ["3"] = "11111 00010 00100 00010 00001 10001 01110",
    ["4"] = "00010 00110 01010 10010 11111 00010 00010", ["5"] = "11111 10000 11110 00001 00001 10001 01110",
    ["6"] = "00110 01000 10000 11110 10001 10001 01110", ["7"] = "11111 00001 00010 00100 01000 01000 01000",
    ["8"] = "01110 10001 10001 01110 10001 10001 01110", ["9"] = "01110 10001 10001 01111 00001 00010 01100",
    [" "] = "00000 00000 00000 00000 00000 00000 00000", ["."] = "00000 00000 00000 00000 00000 01100 01100",
    [","] = "00000 00000 00000 00000 01100 00100 01000", [":"] = "00000 01100 01100 00000 01100 01100 00000",
    [";"] = "00000 01100 01100 00000 01100 00100 01000", ["'"] = "01100 00100 01000 00000 00000 00000 00000",
    ['"'] = "01010 01010 01010 00000 00000 00000 00000", ["-"] = "00000 00000 00000 11111 00000 00000 00000",
    ["/"] = "00000 00001 00010 00100 01000 10000 00000", ["&"] = "01100 10010 10100 01000 10101 10010 01101",
    ["!"] = "00100 00100 00100 00100 00100 00000 00100", ["?"] = "01110 10001 00001 00010 00100 00000 00100",
    ["("] = "00010 00100 01000 01000 01000 00100 00010", [")"] = "01000 00100 00010 00010 00010 00100 01000",
    ["+"] = "00000 00100 00100 11111 00100 00100 00000", ["#"] = "01010 01010 11111 01010 11111 01010 01010",
    ["%"] = "11000 11001 00010 00100 01000 10011 00011", ["="] = "00000 00000 11111 00000 11111 00000 00000",
    ["_"] = "00000 00000 00000 00000 00000 00000 11111", ["*"] = "00000 00100 10101 01110 10101 00100 00000",
    ["@"] = "01110 10001 00001 01101 10101 10101 01110", ["~"] = "00000 00000 01000 10101 00010 00000 00000",
    ["\1"] = "00000 00000 00000 01100 01100 00000 00000",   -- centre dot (·)
}
local BITS = {}
for ch, rows in pairs(GLYPHS) do
    local b = {}
    for row in rows:gmatch("%d+") do b[#b + 1] = row end
    BITS[ch] = b
end
local SUBST = {
    ["·"] = "\1", ["•"] = "\1", ["–"] = "-", ["—"] = "-", ["‘"] = "'", ["’"] = "'",
    ["“"] = '"', ["”"] = '"', ["…"] = "...", ["é"] = "E", ["É"] = "E", ["è"] = "E",
    ["á"] = "A", ["à"] = "A", ["ó"] = "O", ["ö"] = "O", ["ü"] = "U", ["ñ"] = "N",
}

local function cells(s)
    local out = {}
    for ch in (s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local s1 = SUBST[ch] or ch:upper()
        for c in s1:gmatch(".") do out[#out + 1] = BITS[c] and c or "?" end
    end
    return out
end

local FL = DISPLAYS.blue

local function draw_matrix(ev, x, y, n, p, chars, color, glow)
    local dot = p * 0.7
    local ghost, lit = {}, {}
    for i = 1, n do
        local cx = x + (i - 1) * 6 * p
        local b = BITS[chars[i] or " "]
        for r = 1, 7 do
            for c = 1, 5 do
                local path = rect_path(cx + (c - 1) * p, y + (r - 1) * p, dot, dot)
                if b[r]:sub(c, c) == "1" then lit[#lit + 1] = path else ghost[#ghost + 1] = path end
            end
        end
    end
    if #ghost > 0 then ev[#ev + 1] = shape(table.concat(ghost), FL[3]) end
    if #lit > 0 then
        lit = table.concat(lit)
        if glow then ev[#ev + 1] = shape(lit, color, 150, p * 0.9) end
        ev[#ev + 1] = shape(lit, color)
    end
end

-- Right-aligned text in n cells
local function rpad(s, n)
    local c = cells(s)
    local out = {}
    for i = 1, n do out[i] = c[#c - n + i] or " " end
    return out
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local overlay = mp.create_osd_overlay("ass-events")
local backdrop = mp.create_osd_overlay("ass-events")
backdrop.z = -1
local states = {}                      -- latest published state, by source id
local running = {}                     -- source id -> true
local starting = {}                    -- source id -> time we started it
local levels = { l = -90, r = -90 }
local audio = { volume = nil, muted = false, device = nil }
local started = os.time()
local hits = {}
local pressed = { id = nil, until_t = 0 }
local notice = { text = nil, until_t = 0 }
local scroll = { text = nil, cells = {}, pos = 0, next_t = 0 }

local function sock(src) return "/tmp/mpv-" .. src.kind end

local function send(path, ...)                  -- a command to another mpv's socket
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "/bin/sh", "-c", 'printf "%s\\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1', "sh",
                 utils.format_json({ command = { ... } }), path },
    }, function() end)
end

local function send_now(path, ...)              -- the same, waiting for it (when quitting)
    utils.subprocess({ cancellable = false,
        args = { "/bin/sh", "-c", 'printf "%s\\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1', "sh",
                 utils.format_json({ command = { ... } }), path } })
end

local function source_theme(src)
    local mode = src.kind
    local f = io.open(mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. mode .. "-prefs" }), "r")
    local c
    if f then
        for line in f:lines() do c = line:match("^colour=(%a+)$") or c end
        f:close()
    end
    return DISPLAYS[c or ""] and c or (mode == "music" and "amber" or "blue")
end

local function update_theme()
    FL = DISPLAYS[colour ~= "auto" and colour or source_theme(BY_ID[input])] or DISPLAYS.blue
end

---------------------------------------------------------------------------
-- Choosing a source
---------------------------------------------------------------------------

local render
local arrange                          -- STACK (defined with the buttons)

-- Full volume to the chosen source, none to the rest; level bars from it
local function apply()
    for _, src in ipairs(SOURCES) do
        if running[src.id] then
            local want = src.id == input and FULL or 0
            local st = states[src.id] or {}
            if st.volume ~= want then send(sock(src), "set", "volume", tostring(want)) end
        end
    end
end

-- A fish command (tv, radio, youtube, music), in the background; what it
-- prints goes to /tmp/mpv-tvh-<source>.log
local launched = {}                    -- source id -> when the preamp started it
local ROW2 = (mp.get_opt("preamp-row2") or ""):match("^%+%d+%+%d+$")   -- STACK's second row
local function run(src, command)
    if command == src.start then launched[src.id] = os.time() end
    -- Stacked: the faceplate opens straight into the second row (__tvh reads
    -- MPV_TVH_AT), rather than where it lives and then moving
    if stacked and ROW2 and src.id ~= "tv" then command = "set -x MPV_TVH_AT " .. ROW2 .. "; " .. command end
    mp.command_native_async({ name = "subprocess", playback_only = false, detach = true,
        args = { "/bin/sh", "-c", 'exec fish -c "$1" >"$2" 2>&1', "sh", command,
                 "/tmp/mpv-tvh-" .. src.id .. ".log" } }, function() end)
end

local secondary_switch                 -- the secondary picture slot (defined with MONITOR)

local static = { w = 0, h = 0 }       -- the drawn front panel (rebuilt when it changes)

local function choose(id, quiet)
    local src = BY_ID[id]
    if not src then return end
    if input ~= id then
        if running[input] then send(sock(BY_ID[input]), "script-message", "vu-preamp", "no") end
        if secondary_switch then secondary_switch(input, id) end
        if input == "tv" or id == "tv" or input == "tuner" or id == "tuner" then static.w = 0 end   -- LIBRARY <-> GUIDE
        input = id
        save_prefs()
        update_theme()
        scroll.text = nil
    end
    if running[id] then
        send(sock(src), "set", "mute", "no")       -- the preamp's MUTE is the one that counts
        send(sock(src), "script-message", "vu-preamp", dim_manual and "no" or "yes")
        if src.cmd ~= "radio" then run(src, src.cmd .. " --panel") end   -- its faceplate, if it's gone
    elseif not starting[id] or os.time() - starting[id] > 15 then
        starting[id] = os.time()                 -- not running: start it
        run(src, src.start)
        if not quiet then notice.text, notice.until_t = "STARTING", mp.get_time() + 6 end
    end
    apply()
    if stacked then arrange(not running[id]) end   -- again once a new one's windows are up
    render()
end

---------------------------------------------------------------------------
-- The Mac's volume and sound device
---------------------------------------------------------------------------

local function read_audio()
    local f = io.open(AUDIO_FILE, "r")
    local line = f and f:read("*l")
    if f then f:close() end
    local v, m, name = (line or ""):match("^(%d+)%s+(%d)%s*(.*)$")
    if v then
        audio.volume, audio.muted = tonumber(v), m == "1"
        audio.device = name ~= "" and name or nil
    end
end

-- Without Hammerspoon's file, ask macOS now and then
local function poll_volume()
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "osascript", "-e", "get volume settings" } }, function(_, r)
            local out = (r and r.stdout) or ""
            local v = tonumber(out:match("output volume:(%d+)") or "")
            if v then
                audio.volume = v
                audio.muted = out:match("output muted:true") ~= nil
                render()
            end
        end)
end

local function set_volume(v)
    v = math.max(0, math.min(100, v))
    audio.volume = v
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { "osascript", "-e", "set volume output volume " .. v } }, function() end)
    render()
end

local function toggle_mute()
    audio.muted = not audio.muted
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { "osascript", "-e", "set volume output muted " .. tostring(audio.muted) } }, function() end)
    render()
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

local L = {}
-- Left: badge, DISPLAY buttons, POWER. Top: the display. Bottom: INPUT,
-- MONITOR and MUTE keys. Right: the VOLUME knob.
local function layout()
    local P = { x = 10, y = 8, w = GW - 20, h = GH - 16 }
    local knob = { x = GW - 40 - 165, y = GH / 2 - 14, r = 140 }
    local D = { x = 330, y = 34, h = 232 }
    D.w = knob.x - knob.r - 56 - D.x
    local pad = 24
    local pn = math.min(15, (D.w - 2 * pad) / (16 * 6 - 1))     -- 12 name cells, gap, 3 volume cells
    local prt = 7
    local buttons = {}
    for k, l in ipairs({ "CLOCK", "DIM", "COLOUR", "SCROLL", "STACK", "REC OUT", "SETUP" }) do
        local r, c = math.floor((k - 1) / 3), (k - 1) % 3
        buttons[#buttons + 1] = { x = 34 + c * 88, y = 180 + r * 80, w = 76, h = 30, r = 15, label = l }
    end
    local KY, KH, KW, KG = 300, 116, 132, 14                    -- the bottom row of keys
    local inputs, monitor = {}, {}
    for k, src in ipairs(SOURCES) do
        inputs[#inputs + 1] = { x = D.x + (k - 1) * (KW + KG), y = KY, w = KW, h = KH, r = 10, src = src }
    end
    local mx0 = D.x + #SOURCES * (KW + KG) + 40
    for k, m in ipairs(MONITOR) do
        monitor[#monitor + 1] = { x = mx0 + (k - 1) * (KW + KG), y = KY, w = KW, h = KH, r = 10,
                                  id = m.id, caption = m.caption, icon = m.icon }
    end
    local mute = { x = mx0 + #MONITOR * (KW + KG) + 40, y = KY, w = KW, h = KH, r = 10 }
    L = { P = P, D = D, pad = pad, pn = pn, prt = prt, name_y = D.y + 46,
          rt_y = D.y + D.h - 7 * prt - 18, buttons = buttons, inputs = inputs, knob = knob,
          monitor = monitor, mute = mute, power = { x = 52, y = GH - 56, r = 20 } }
end

local function hit(id, x, y, w, h, action, wheel)
    hits[#hits + 1] = { id = id, x1 = N(x), y1 = N(y), x2 = N(x + w), y2 = N(y + h), action = action, wheel = wheel }
end

local function cycle_colour()
    local i = 1
    for k, c in ipairs(CYCLE) do if c == colour then i = k end end
    colour = CYCLE[i % #CYCLE + 1]
    save_prefs()
    update_theme()
    notice.text, notice.until_t = "COLOUR  " .. colour, mp.get_time() + 1.6
    render()
end

-- Ask Hammerspoon to stack the windows (or put them back), the chosen
-- source's faceplate in front
arrange = function(again)
    local url = string.format("hammerspoon://tvh-view?mode=%s&input=%s&at=%s",
        stacked and "stack" or "full", input, (STACK_AT:gsub("%+", "_")))
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { "open", "-g", url } }, function() end)
    if again then mp.add_timeout(2, function() arrange(false) end) end   -- windows still opening
end

local function toggle_stack()
    stacked = not stacked
    save_prefs()
    arrange(false)
    notice.text, notice.until_t = stacked and "STACKED" or "SPREAD OUT", mp.get_time() + 1.6
    render()
end

-- REC OUT: off -> TV -> TUNER -> NET; the recorder records that source,
-- whatever you're listening to
local function cycle_rec_out()
    local i = 1
    for k, r in ipairs(REC_CYCLE) do if r == rec_out then i = k end end
    rec_out = REC_CYCLE[i % #REC_CYCLE + 1]
    save_prefs()
    notice.text, notice.until_t = "REC OUT  " .. (rec_out == "off" and "OFF" or BY_ID[rec_out].label),
        mp.get_time() + 1.6
    render()
end

local function recording()
    local f = io.open("/tmp/mpv-recorder.state", "r")
    local line = f and f:read("*l")
    local t = f and tonumber(f:read("*l") or "")
    if f then f:close() end
    return line and line:match("^rec (%a+)")
end

-- SETUP: Tvheadend's address and the presets, in the TV's guide (the TV
-- starts if it isn't on)
local function setup()
    local tv = BY_ID.tv
    if running.tv then
        send("/tmp/mpv-" .. tv.face, "script-message", "guide-setup")
    else
        run(tv, tv.start .. (input ~= "tv" and " --volume=0" or ""))
        mp.add_timeout(4, function() send("/tmp/mpv-" .. tv.face, "script-message", "guide-setup") end)
    end
    notice.text, notice.until_t = "SETUP  ·  IN THE GUIDE", mp.get_time() + 2
    render()
end

local ACTIONS = {
    SETUP = setup,
    ["REC OUT"] = cycle_rec_out,
    STACK  = toggle_stack,
    CLOCK  = function() show_clock = not show_clock; save_prefs(); render() end,
    DIM    = function()                    -- also stops the level bars (and the player measuring)
        dim_manual = not dim_manual
        save_prefs()
        if running[input] then
            send(sock(BY_ID[input]), "script-message", "vu-preamp", dim_manual and "no" or "yes")
        end
        render()
    end,
    COLOUR = cycle_colour,
    SCROLL = function()                    -- AUTO (only while the preamp is active) -> OFF -> ON
        scroll_mode = ({ auto = "off", off = "on", on = "auto" })[scroll_mode]
        save_prefs()
        notice.text, notice.until_t = "SCROLL  " .. scroll_mode:upper(), mp.get_time() + 1.6
        render()
    end,
}

-- MONITOR: is that window open for the chosen source, and open / close it
local function alive(file)
    local f = io.open(file, "r")
    local t = f and tonumber(f:read("*l") or "")
    if f then f:close() end
    return t ~= nil and os.time() - t <= 3
end

local function window_on(id, sid)
    sid = sid or input
    local src, st = BY_ID[sid], states[sid] or {}
    if not running[sid] or not src.windows[id] then return false end
    if id == "video" then
        return st.vid ~= nil and st.vid ~= false and st.vid ~= "no" and (st["playlist-pos"] or -1) >= 0
    end
    if id == "vu" then return alive("/tmp/mpv-" .. src.kind .. ".vu.alive") end
    if id == "list" then return alive("/tmp/mpv-" .. src.kind .. ".list.alive") end
    return alive("/tmp/mpv-" .. src.kind .. ".lib.alive")
end

local function toggle_window(id, sid)
    sid = sid or input
    local src = BY_ID[sid]
    if not running[sid] or not src.windows[id] then return end
    send("/tmp/mpv-" .. src.face, "script-message", "window-toggle", id)
end

-- The secondary picture slot (under the TV window): every source's windows
-- stay open there, stacked; choosing a source brings its picture, VU meter
-- and playlist to the front (Hammerspoon raises them, hammerspoon://tvh-raise)
secondary_switch = function(_, new)
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { "open", "-g", "hammerspoon://tvh-raise?input=" .. new } }, function() end)
end

local function power()                          -- everything off
    for _, src in ipairs(SOURCES) do
        if running[src.id] then send(sock(src), "quit") end
    end
    send("/tmp/mpv-recorder", "quit")
    mp.add_timeout(0.5, function() mp.command("quit") end)
end


local function build_static()
    local ev = {}
    hits = {}
    local P, D = L.P, L.D
    ev[#ev + 1] = shape(rrect_path(P.x, P.y + 8, P.w, P.h, 10), C.plate_lo, 0, 14)
    ev[#ev + 1] = shape(rrect_path(P.x, P.y, P.w, P.h, 10), C.plate_top)
    ev[#ev + 1] = shape(rrect_path(P.x, P.y + 4, P.w, P.h - 4, 10), C.plate)
    local brush = {}
    for i = 0, math.floor((P.h - 20) / 4) do
        brush[#brush + 1] = rect_path(P.x + 12, P.y + 10 + i * 4 + (i * 7 % 3), P.w - 24, 1)
    end
    ev[#ev + 1] = shape(table.concat(brush), C.streak, 247)
    ev[#ev + 1] = shape(rect_path(P.x + 10, P.y + P.h - 3, P.w - 20, 2), C.plate_top, 120)

    ev[#ev + 1] = text(32, 44, 4, 30, C.silk, "mpv-tvh", true, 2)
    ev[#ev + 1] = text(34, 80, 4, 16, C.silk, "PR-252", true, 2)
    ev[#ev + 1] = text(34, 102, 4, 11, C.silk_dim, "CONTROL AMPLIFIER", false, 3)
    local pw = L.power
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y + 3, pw.r), C.plate_lo, 0, 4)
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y, pw.r), C.button_rim)
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y + 1.5, pw.r - 3), C.button)
    ev[#ev + 1] = text(pw.x + pw.r + 14, pw.y + 9, 4, 13, C.silk, "POWER", false, 2)
    ev[#ev + 1] = shape(circle_path(pw.x + pw.r + 20, pw.y - 9, 6), C.led_on, 140, 8)
    ev[#ev + 1] = shape(circle_path(pw.x + pw.r + 20, pw.y - 9, 3.5), C.led_on)
    hit("power", pw.x - pw.r, pw.y - pw.r, 2 * pw.r, 2 * pw.r, power)

    ev[#ev + 1] = shape(rrect_path(D.x - 8, D.y - 8, D.w + 16, D.h + 16, 8), C.bezel)
    ev[#ev + 1] = shape(rrect_path(D.x - 8, D.y - 8, D.w + 16, 4, 2), "#000000", 60)
    ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), C.window)

    local function key(b, label, caption, size, icon)
        ev[#ev + 1] = shape(rrect_path(b.x, b.y + 2, b.w, b.h, b.r), C.plate_lo)
        ev[#ev + 1] = shape(rrect_path(b.x, b.y, b.w, b.h, b.r), C.button_rim)
        ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button)
        if icon then
            local sz, cx, cy = math.min(b.w, b.h) * 0.24, b.x + b.w / 2, b.y + b.h / 2 + 2
            ev[#ev + 1] = shape(icon_path(icon, cx, cy + 1.5, sz), C.plate_lo)
            ev[#ev + 1] = shape(icon_path(icon, cx, cy, sz), C.silk, 30)
        end
        if label then
            ev[#ev + 1] = text(b.x + b.w / 2 + 1, b.y + b.h / 2 + 3.5, 5, size, C.plate_lo, label, true, 2)
            ev[#ev + 1] = text(b.x + b.w / 2, b.y + b.h / 2 + 2, 5, size, C.silk, label, true, 2)
        end
        ev[#ev + 1] = text(b.x + b.w / 2, b.y + b.h + 6, 8, 13, C.silk, caption, false, 2)
    end
    for i, b in ipairs(L.buttons) do
        key(b, nil, b.label)
        hit("b" .. i, b.x, b.y, b.w, b.h, ACTIONS[b.label])
    end
    ev[#ev + 1] = text(L.buttons[1].x, L.buttons[1].y - 8, 1, 12, C.silk_dim, "DISPLAY", false, 3)
    for i, b in ipairs(L.monitor) do
        if b.id == "library" and (input == "tv" or input == "tuner") then key(b, nil, "GUIDE", nil, "guide")   -- the TV's, the radio's
        else key(b, nil, b.caption, nil, b.icon) end
        hit("m" .. i, b.x, b.y, b.w, b.h, function() toggle_window(b.id) end)
    end
    key(L.mute, nil, "MUTE", nil, "mute")
    hit("mute", L.mute.x, L.mute.y, L.mute.w, L.mute.h, toggle_mute)
    ev[#ev + 1] = text(L.monitor[1].x, L.monitor[1].y - 8, 1, 12, C.silk_dim, "MONITOR", false, 3)
    for i, b in ipairs(L.inputs) do
        key(b, b.src.label, b.src.caption, 20)
        hit("i" .. i, b.x, b.y, b.w, b.h, function() choose(b.src.id) end)
    end
    ev[#ev + 1] = text(L.inputs[1].x, L.inputs[1].y - 8, 1, 12, C.silk_dim, "INPUT", false, 3)

    -- Volume knob: knurled rim, plain face
    local k = L.knob
    ev[#ev + 1] = shape(circle_path(k.x, k.y + 5, k.r + 6), C.plate_lo, 0, 10)
    ev[#ev + 1] = shape(circle_path(k.x, k.y, k.r + 4), "#070708")
    ev[#ev + 1] = shape(circle_path(k.x, k.y, k.r), C.knob_rim)
    local ridges = {}
    for i = 0, 89 do
        local a = math.rad(i * 4)
        ridges[#ridges + 1] = line_path(k.x + (k.r - 14) * math.sin(a), k.y - (k.r - 14) * math.cos(a),
                                        k.x + (k.r - 1) * math.sin(a), k.y - (k.r - 1) * math.cos(a), 1.6)
    end
    ev[#ev + 1] = shape(table.concat(ridges), C.knob)
    ev[#ev + 1] = shape(circle_path(k.x, k.y, k.r - 16), "#000000", 0, 2)
    ev[#ev + 1] = shape(circle_path(k.x, k.y - 1, k.r - 17), C.knob_face)
    ev[#ev + 1] = shape(circle_path(k.x - 10, k.y - 14, k.r - 40), "#FFFFFF", 248, 18)
    ev[#ev + 1] = text(k.x, k.y + k.r + 22, 8, 13, C.silk, "VOLUME", false, 2)
    hit("knob", k.x - k.r, k.y - k.r, 2 * k.r, 2 * k.r, toggle_mute, true)

    hit("panel", P.x, P.y, P.w, P.h)
    backdrop.data = table.concat(ev, "\n")
    backdrop:update()
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

local function lamp(ev, x, y, label, level)       -- level: 2 lit, 1 dim, 0 off
    ev[#ev + 1] = text(x, y, 4, 13, level == 2 and FL[1] or level == 1 and FL[2] or FL[3], label, true, 2,
        level == 2 and 0.6 or 0)
    return x + (#label * 14 + 30)
end

local function hi_res(st)
    if (st["current-tracks/audio/demux-samplerate"] or 0) > 48000 then return true end
    local codec, fmt = st["audio-codec-name"] or "", st["audio-params/format"] or ""
    return (codec:match("flac") or codec:match("alac") or codec:match("pcm") or codec:match("wavpack")
            or codec:match("ape") or codec:match("tta")) ~= nil and (fmt:match("s24") or fmt:match("s32")) ~= nil
end

-- What the chosen source is playing, for the lower line
local function playing(src, st)
    if not running[src.id] then
        if not starting[src.id] then return "OFF  ·  PRESS TO START" end
        if os.time() - starting[src.id] < 15 then return "STARTING" end
        return "DIDN'T START  ·  SEE /TMP/MPV-TVH-" .. src.id:upper() .. ".LOG"
    end
    local pos = (st["playlist-pos"] or -1) + 1
    if st.stopped and (src.id == "tv" or src.id == "tuner") then
        local t = (st.titles or {})[st.stopped_index or 0]
        return (t and (t .. "  · ") or "") .. "STOPPED"
    end
    local title = (st.titles or {})[pos]
    if src.id == "tv" then
        return title or st["media-title"] or "NO CHANNEL"
    elseif src.id == "tuner" then
        local icy = st["metadata/by-key/icy-title"]
        return (icy and icy ~= "") and ((title and (title .. "  · ") or "") .. icy) or title or "NO STATION"
    elseif src.id == "vid" then
        if pos < 1 then return "NO VIDEO" end
        return title or st["media-title"] or ""
    elseif src.id == "net" then
        if pos < 1 then return "NOTHING PLAYING" end
        return st["media-title"] or title or ""
    else
        if pos < 1 then return "NO DISC" end
        local t = st["metadata/by-key/title"] or title or ""
        local a = st["metadata/by-key/artist"]
        return a and (t .. "  · " .. a) or t
    end
end

local function db_bars(db, n)
    return math.max(0, math.min(n, math.floor(n * (db + 42) / 42 + 0.5)))
end

render = function()
    local w, h = mp.get_osd_size()
    if not w or w == 0 or h == 0 then return end
    if w ~= static.w or h ~= static.h then
        overlay.res_x, overlay.res_y = w, h
        backdrop.res_x, backdrop.res_y = w, h
        S = h / GH
        GW = GH * w / h
        layout()
        build_static()
        static.w, static.h = w, h
    end
    local ev = {}
    local D, src = L.D, BY_ID[input]
    local st = states[input] or {}
    local on = running[input]
    local now = mp.get_time()

    -- Lamps: sources (lit: chosen, dim: running), then the chosen one's
    local x, iy = D.x + L.pad, D.y + 18
    for _, s in ipairs(SOURCES) do
        x = lamp(ev, x, iy, s.label, s.id == input and 2 or (running[s.id] and 1 or 0))
    end
    x = x + 16
    x = lamp(ev, x, iy, "STEREO", (on and (st["audio-params/channel-count"] or 0) >= 2) and 2 or 0)
    x = lamp(ev, x, iy, "HI-RES", (on and hi_res(st)) and 2 or 0)
    x = lamp(ev, x, iy, "MUTE", audio.muted and 2 or 0)
    if rec_out ~= "off" then
        x = lamp(ev, x + 16, iy, "REC " .. BY_ID[rec_out].label, recording() and 2 or 1)
    end
    local out = st.audio_out or audio.device or "MAC OUTPUT"
    ev[#ev + 1] = text(D.x + D.w - L.pad, iy, 6, 13, FL[2], "OUT  " .. out:upper(), true, 2)

    -- Source name and volume
    local quiet = audio.muted or not on
    draw_matrix(ev, D.x + L.pad, L.name_y, 12, L.pn, cells(src.name), quiet and FL[2] or FL[1], not quiet)
    local vx = D.x + D.w - L.pad - (3 * 6 - 1) * L.pn
    draw_matrix(ev, vx, L.name_y, 3, L.pn, rpad(audio.muted and "" or tostring(audio.volume or ""), 3),
        FL[1], true)

    -- Lower line: notice or what's playing (scrolls), the clock, level bars
    local prt, ry = L.prt, L.rt_y
    local bars_w = math.floor((D.w - 2 * L.pad) * 0.3)
    local clock_cells = show_clock and 6 or 0
    local cap = math.floor((D.w - 2 * L.pad - bars_w - 20) / (6 * prt)) - clock_cells
    local line = (notice.text and now < notice.until_t) and notice.text or playing(src, st)
    if line ~= scroll.text then
        scroll.text, scroll.cells, scroll.pos, scroll.next_t = line, cells(line), 0, now + 2.5
    end
    scroll.cap = cap
    local view = scroll.cells
    if #scroll.cells > cap then
        view = {}
        for i = 1, cap do
            local k = (scroll.pos + i - 1) % (#scroll.cells + 4) + 1
            view[i] = scroll.cells[k] or " "
        end
    end
    draw_matrix(ev, D.x + L.pad, ry, cap, prt, view, FL[2], false)
    if show_clock then
        draw_matrix(ev, D.x + L.pad + cap * 6 * prt + 6 * prt, ry, 5, prt, cells(os.date("%H:%M")), FL[2], false)
    end
    local bx = D.x + D.w - L.pad - bars_w
    local n = math.floor((bars_w - 24) / 14)
    for i, ch in ipairs({ "l", "r" }) do
        local y = ry + (i == 1 and 4 or 30)
        ev[#ev + 1] = text(bx, y + 8, 4, 11, FL[2], ch:upper(), true, 0)
        local lit = (on and not audio.muted and not dim_manual) and db_bars(levels[ch], n) or 0
        local litp, offp = {}, {}
        for k = 1, n do
            local path = rect_path(bx + 22 + (k - 1) * 14, y, 9, 17)
            if k <= lit then litp[#litp + 1] = path else offp[#offp + 1] = path end
        end
        if #offp > 0 then ev[#ev + 1] = shape(table.concat(offp), FL[3]) end
        if #litp > 0 then
            ev[#ev + 1] = shape(table.concat(litp), FL[1], 150, 5)
            ev[#ev + 1] = shape(table.concat(litp), FL[1])
        end
    end

    -- Input LEDs: green for the chosen source, faint for others running
    for _, b in ipairs(L.inputs) do
        local id = b.src.id
        local lx, ly = b.x + b.w - 16, b.y + 16
        if id == input then ev[#ev + 1] = shape(circle_path(lx, ly, 6), C.led_on, 140, 8) end
        ev[#ev + 1] = shape(circle_path(lx, ly, 3.5),
            id == input and C.led_on or (running[id] and C.led_dim or C.led_off))
    end
    local function led(b, lit)
        local lx, ly = b.x + b.w - 16, b.y + 16
        if lit then ev[#ev + 1] = shape(circle_path(lx, ly, 6), C.led_on, 140, 8) end
        ev[#ev + 1] = shape(circle_path(lx, ly, 3.5), lit and C.led_on or C.led_off)
    end
    for _, b in ipairs(L.monitor) do
        if running[input] and BY_ID[input].windows[b.id] then
            led(b, window_on(b.id))
        else                                         -- not for this source: greyed out
            ev[#ev + 1] = shape(rect_path(b.x - 2, b.y - 2, b.w + 4, b.h + 30), C.plate, 70)
        end
    end
    led(L.mute, audio.muted)
    for _, b in ipairs(L.buttons) do
        if b.label == "REC OUT" then
            local lx, ly, on = b.x + b.w - 16, b.y + b.h / 2, rec_out ~= "off"
            if on then ev[#ev + 1] = shape(circle_path(lx, ly, 6), C.led_on, 140, 8) end
            ev[#ev + 1] = shape(circle_path(lx, ly, 3.5), on and C.led_on or C.led_off)
        end
        if b.label == "STACK" then
            local lx, ly = b.x + b.w - 16, b.y + b.h / 2
            if stacked then ev[#ev + 1] = shape(circle_path(lx, ly, 6), C.led_on, 140, 8) end
            ev[#ev + 1] = shape(circle_path(lx, ly, 3.5), stacked and C.led_on or C.led_off)
        end
    end

    -- Volume knob marker: 7 o'clock (0) to 5 o'clock (100)
    local k = L.knob
    local a = math.rad(-135 + 270 * (audio.volume or 0) / 100)
    local mx, my = k.x + (k.r - 44) * math.sin(a), k.y - (k.r - 44) * math.cos(a)
    ev[#ev + 1] = shape(circle_path(mx, my, 14), FL[1], 150, 12)
    ev[#ev + 1] = shape(circle_path(mx, my, 7), FL[1])

    if dim_manual or mp.get_property_bool("focused", true) == false then
        ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), "#000000", 255 - DIM_ALPHA)
    end
    if pressed.id and now < pressed.until_t then
        for i, b in ipairs(L.buttons) do
            if pressed.id == "b" .. i then
                ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button_dn)
            end
        end
        for i, b in ipairs(L.monitor) do
            if pressed.id == "m" .. i then
                ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button_dn)
            end
        end
        if pressed.id == "mute" then
            local b = L.mute
            ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button_dn)
        end
        for i, b in ipairs(L.inputs) do
            if pressed.id == "i" .. i then
                ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button_dn)
            end
        end
    end

    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

---------------------------------------------------------------------------
-- Mouse
---------------------------------------------------------------------------

local function hit_at()
    local m = mp.get_property_native("mouse-pos") or {}
    local mx, my = m.x or -1, m.y or -1
    for _, a in ipairs(hits) do
        if mx >= a.x1 and mx <= a.x2 and my >= a.y1 and my <= a.y2 then return a end
    end
end

mp.add_forced_key_binding("MBTN_LEFT", "preamp-click", function(e)
    if e.event ~= "down" then return end
    local a = hit_at()
    if a and a.action then
        pressed.id, pressed.until_t = a.id, mp.get_time() + 0.15
        a.action()
        render()
        mp.add_timeout(0.16, render)
    else
        pcall(mp.commandv, "begin-vo-dragging")
    end
end, { complex = true })
mp.commandv("keybind", "MBTN_LEFT_DBL", "ignore")

-- Scroll over the knob for volume
local function wheel(d)
    return function()
        local a = hit_at()
        if a and a.wheel then set_volume((audio.volume or 0) + d * 2) end
    end
end
mp.add_forced_key_binding("WHEEL_UP", "preamp-vol-up", wheel(1))
mp.add_forced_key_binding("WHEEL_DOWN", "preamp-vol-down", wheel(-1))

mp.register_script_message("preamp-select", function(id) choose(id) end)
mp.register_script_message("preamp-power", function() power() end)   -- Alt + 1 on the pad: off
mp.register_script_message("preamp-audio", function() read_audio(); render() end)

---------------------------------------------------------------------------
-- Follow the sources
---------------------------------------------------------------------------

local first_scan = true
local function scan()
    local changed = false
    for _, src in ipairs(SOURCES) do
        local f = io.open("/tmp/mpv-" .. src.kind .. ".state.json", "r")
        local raw = f and f:read("*a")
        if f then f:close() end
        local s = raw and utils.parse_json(raw)
        local up = s and not s.closed and os.time() - (s.t or 0) <= 6 or false
        if up ~= (running[src.id] or false) then
            running[src.id] = up or nil
            changed = true
            if up then
                starting[src.id] = nil
                -- Started some other way (its own command): it becomes the source
                if not first_scan and src.id ~= input and os.time() - started > 3
                    and not (launched[src.id] and os.time() - launched[src.id] < 60) then
                    choose(src.id, true)
                elseif src.id == input then
                    send(sock(src), "script-message", "vu-preamp", dim_manual and "no" or "yes")
                end
                if stacked then arrange(true) end      -- its faceplate into the stack
            end
        end
        states[src.id] = up and s or nil
    end
    first_scan = false
    apply()
    return changed
end

mp.add_periodic_timer(0.5, function()
    scan()
    update_theme()
    render()
end)

-- Level bars, about 15 times a second
local last_levels = ""
mp.add_periodic_timer(1 / 15, function()
    local moved = false
    local scrolling = scroll_mode == "on"
        or (scroll_mode == "auto" and mp.get_property_bool("focused", true) ~= false)
    if not scrolling then
        if scroll.pos ~= 0 then scroll.pos = 0; moved = true end    -- back to the start, held
    elseif #scroll.cells > (scroll.cap or 999) and mp.get_time() >= scroll.next_t then
        scroll.pos = (scroll.pos + 1) % (#scroll.cells + 4)
        scroll.next_t = mp.get_time() + (scroll.pos == 0 and 2.5 or 0.32)
        moved = true
    end
    if not running[input] or dim_manual then
        if moved then render() end
        return
    end
    local f = io.open("/tmp/mpv-" .. BY_ID[input].kind .. ".vu", "r")
    local line = f and f:read("*l")
    if f then f:close() end
    local l, r = (line or ""):match("^%d+ %d %a+ (%S+) (%S+)")
    if l and line ~= last_levels then
        last_levels = line
        levels.l, levels.r = tonumber(l) or -90, tonumber(r) or -90
        moved = true
    end
    if moved then render() end
end)

mp.add_periodic_timer(2, function()
    local f = io.open(AUDIO_FILE, "r")
    if f then f:close(); read_audio() else poll_volume() end
end)

-- Leaving: everything back to full volume, as without a preamp
mp.register_event("shutdown", function()
    for _, src in ipairs(SOURCES) do
        if running[src.id] then
            send_now(sock(src), "set", "volume", tostring(FULL))
            send_now(sock(src), "script-message", "vu-preamp", "no")
        end
    end
end)

do
    local dir = PREFS_FILE:match("(.*)/")
    if dir then utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false }) end
end
mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
mp.observe_property("osd-dimensions", "native", function() render() end)
mp.observe_property("focused", "native", function() render() end)
read_audio()
if not audio.volume then poll_volume() end
update_theme()
scan()
save_prefs()
choose(input, true)
-- Switching on starts the TV and the tuner (the others start when chosen)
do
    local delay = 0.5
    for _, id in ipairs({ "tv", "tuner" }) do
        local src = BY_ID[id]
        if id ~= input and not running[id] then
            mp.add_timeout(delay, function()            -- starting silent: no blip before it's muted
                if not running[id] then
                    launched[id] = os.time()
                    run(src, src.cmd .. " --default --volume=0")
                end
            end)
            delay = delay + 0.7
        end
    end
end
if stacked then mp.add_timeout(1, function() arrange(true) end) end
