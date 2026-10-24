-- faceplate.lua
-- Hi-fi faceplates for mpv-tvh, styled after black 2000s separates: a slim
-- brushed-black unit with a dot-matrix fluorescent display, made for a
-- short, wide window (1816x182 on a Retina screen, about 10:1).
--
-- Chosen by the mpv's control socket:
--   radio       /tmp/mpv-radio: the radio player is its own tuner faceplate
--   TV panel    /tmp/mpv-panel-tv: a separate, media-less mpv window that
--               remote-controls the TV player (/tmp/mpv-tv). It reads the
--               player's state from /tmp/mpv-tv.state.json (written by
--               player-state.lua in the player), sends commands to the
--               player's socket with nc, and closes when the player quits.
--
-- Left to right, the same on both: badge and POWER (quits); DIM, COLOUR
-- and SCROLL; the display (indicator lamps, preset number, signal
-- meter = seconds of stream buffered, station / channel name, and a
-- line with the programme from the Tvheadend EPG: NOW with the time left,
-- then NEXT with its start, a page at a time; the TIMER lamp means
-- Tvheadend is recording, or will record, one of them; or the current
-- track of an internet stream); tall transport keys < >, PLAY and STOP
-- (volume and mute are on the preamp). STOP stops the stream, freeing the
-- tuner (player-state.lua). Scroll over the panel to step through the
-- channels; drag it to move it.
--
-- A Tvheadend recording (WATCH in the guide's recordings) plays in the same
-- player: the display shows its title and position, the PVR lamp is lit,
-- < > skip 30 seconds, and a channel key goes back to live.
--
-- The guide (guide-window.lua; script-opt lib-opts, its mpv options), which
-- Hammerspoon puts under the stack: GUIDE on the preamp (script-message
-- window-toggle library), clicking the display, or the pad's GUIDE key open and close it.
--
-- List mode: Alt + knob 1 press (Alt+Enter) steps through the channels on
-- the display without playing anything: < > or the knob move, PLAY or
-- Enter plays the one shown, Esc or 10 s idle leaves.
--
-- DIM darkens the display by 30%, as does losing focus. SCROLL sets when long
-- text on both lines scrolls: AUTO (only while the window is active), OFF, ON.
-- Colour, DIM and SCROLL are saved per player. The script-messages
-- radio-colour, radio-dim and radio-scroll do the same as the buttons. Script-opt tvh-host (Tvheadend
-- host:port) comes from __tvh.fish.

local mp = require 'mp'
local utils = require 'mp.utils'

local IPC = mp.get_property("input-ipc-server") or ""
local MODE = IPC:match("/mpv%-radio$") and "radio" or IPC:match("/mpv%-panel%-(%a+)$")
if MODE ~= "radio" and MODE ~= "tv" then return end
local REMOTE = MODE ~= "radio"         -- a panel driving a player in another window
local TV = MODE == "tv"
local unpack = unpack or table.unpack

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- Tvheadend: the address SETUP saved (presets.json), or the config's
local TVH_OPT = mp.get_opt("tvh-host")
if TVH_OPT == "" then TVH_OPT = nil end
local function tvh_host()
    local f = io.open((os.getenv("HOME") or "") .. "/.config/mpv-tvh/presets.json", "r")
    local j = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    return (type(j) == "table" and j.host and j.host ~= "") and j.host or TVH_OPT
end
local DEMO = (mp.get_opt("tvh-demo") or "") ~= ""      -- no config: test cards and internet radio

local MODEL = TV and "TV-252" or "TU-252"                       -- badge
local KIND  = TV and "DIGITAL RECEIVER" or "STEREO TUNER"
local REFRESH = 30             -- seconds between EPG refreshes
local SCROLL  = 0.32           -- seconds per character when text scrolls
local HOLD    = 2.5            -- pause at the start of each scroll
local DIM_ALPHA = 77           -- 30% black over the display window

local to_bottom                       -- (below)
local LIB_OPTS = {}
for o in (mp.get_opt("lib-opts") or ""):gmatch("[^|]+") do LIB_OPTS[#LIB_OPTS + 1] = o end

-- Display (fluorescent) colours: lit, dim, unlit ghost
local DISPLAYS = {
    blue  = { "#9FE8FF", "#4E8FA6", "#0B171B" },
    red   = { "#FF5A47", "#9A3326", "#1C0C0A" },
    green = { "#7DFFB0", "#3E9A66", "#0A1912" },
    amber = { "#FFB347", "#A06A22", "#1C1409" },
}
local CYCLE = { "blue", "red", "green", "amber" }

local C = {
    plate     = "#0E0E10",   -- brushed black aluminium
    plate_top = "#1C1C20",   -- top chamfer catching the light
    plate_lo  = "#030304",
    streak    = "#FFFFFF",   -- brushing (drawn almost transparent)
    silk      = "#C9C9CE",   -- printed white legends
    silk_dim  = "#707078",
    window    = "#030506",   -- display window glass
    bezel     = "#1A1A1D",
    button    = "#18181B",
    button_rim= "#3A3A40",
    button_dn = "#0B0B0D",
    led_on    = "#3DDC84",
    led_off   = "#1B1D1C",
}
local FONT = "Helvetica Neue"

-- Saved settings (colour, dim, scroll), one file per player
local PREFS_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. MODE .. "-prefs" })
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
local theme       = DISPLAYS[prefs.colour or ""] and prefs.colour or "blue"
local FL          = DISPLAYS[theme]
local dim_manual  = prefs.dim == "on"
local scroll_mode = ({ auto = 1, off = 1, on = 1 })[prefs.scroll or ""] and prefs.scroll or "auto"
local browse      = nil                -- list mode: { i = entry shown, until_t = }

local function save_prefs()
    local dir = PREFS_FILE:match("(.*)/")
    if dir then utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false }) end
    local f = io.open(PREFS_FILE, "w")
    if not f then return end
    f:write("colour=", theme, "\n",
            "dim=", dim_manual and "on" or "off", "\n", "scroll=", scroll_mode, "\n")
    f:close()
end

---------------------------------------------------------------------------
-- 5x7 dot-matrix font
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

-- Text to a list of displayable characters (uppercase, unknowns as "?")
local function cells(s)
    local out = {}
    for ch in (s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local s1 = SUBST[ch] or ch:upper()
        for c in s1:gmatch(".") do out[#out + 1] = BITS[c] and c or "?" end
    end
    return out
end

---------------------------------------------------------------------------
-- Drawing helpers (ASS). The design is drawn on a grid 240 units high (GW
-- wide, following the window's shape) and scaled to the window by S.
---------------------------------------------------------------------------

local GH = 240
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
    elseif kind == "stop" then                           -- square
        return rect_path(cx - 0.55 * s, cy - 0.55 * s, 1.1 * s, 1.1 * s)
    end
    return ""
end

-- Filled shape; a = transparency 0 (opaque) .. 255 (invisible)
local function shape(path, color, a, blur)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s\\p1}%s{\\p0}",
        col(color), a or 0, f1(N(blur or 0)), path)
end

local function esc(s)
    return ((s or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", " "))
end

local function text(x, y, align, size, color, s, bold, spacing)
    return string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\fsp%s\\b%d\\bord0\\shad0\\1c%s}%s",
        align, f1(N(x)), f1(N(y)), FONT, f1(N(size)), f1(N(spacing or 0)),
        bold and 1 or 0, col(color), esc(s))
end

-- Dot-matrix field: n character cells at (x, y), dot pitch p, unlit dots
-- drawn faintly as a ghost grid
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

local function fmt_duration(seconds)
    local mins = math.floor(seconds / 60)
    if mins < 60 then return string.format("%dM", mins) end
    local h, m = math.floor(mins / 60), mins % 60
    return m == 0 and string.format("%dH", h) or string.format("%dH%02dM", h, m)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local overlay = mp.create_osd_overlay("ass-events")
local PAD = {}                         -- key name -> what it does here, for script-message pad-key
local entries = nil                    -- EPG now/next for the current station
local hits = {}                        -- clickable areas, in window pixels
local pressed = { id = nil, until_t = 0 }
local static = { w = 0, h = 0, data = "" }
local notice = { text = nil, until_t = 0 }   -- brief message on the text line

-- Scrolling text fields: show `cap` characters; longer text steps one
-- character at a time, holding at the start of each pass.
local function scroller(cap) return { cap = cap, text = nil, cells = {}, pos = 0, next_t = 0 } end
local scroll_name = scroller(13)
local scroll_rt   = scroller(24)

local function scroll_set(sc, s)
    if s == sc.text then return end
    sc.text, sc.cells, sc.pos, sc.next_t = s, cells(s), 0, mp.get_time() + HOLD
end

local function scroll_view(sc)
    local n = #sc.cells
    if n <= sc.cap then return sc.cells end
    local out, loop = {}, n + 4                 -- 4 blank cells between passes
    for i = 1, sc.cap do
        local k = (sc.pos + i - 1) % loop + 1
        out[i] = k <= n and sc.cells[k] or " "
    end
    return out
end

local function scroll_tick(sc, now)
    local n = #sc.cells
    if n <= sc.cap or now < sc.next_t then return false end
    sc.pos = (sc.pos + 1) % (n + 4)
    if sc.pos == 0 then sc.passes = (sc.passes or 0) + 1 end   -- back to the start: one pass done
    sc.next_t = now + (sc.pos == 0 and HOLD or SCROLL)
    return true
end

---------------------------------------------------------------------------
-- Player state: the radio reads and drives its own player; the TV panel
-- mirrors the TV player's published state and sends it commands.
---------------------------------------------------------------------------

local PLAYER_SOCK  = "/tmp/mpv-" .. MODE
local PLAYER_STATE = "/tmp/mpv-" .. MODE .. ".state.json"
local remote = {}                      -- latest state from the player

local function get(p, default)
    local v
    if REMOTE then v = remote[p]
    elseif p == "stopped" then v = mp.get_property_native("user-data/tvh-stopped")      -- player-state.lua
    elseif p == "stopped_index" then v = mp.get_property_native("user-data/tvh-stopped-index")
    elseif p == "nosignal" then v = mp.get_property_native("user-data/tvh-nosignal")
    elseif p == "player_notice" then v = mp.get_property_native("user-data/tvh-notice")
    elseif p == "recording" then v = mp.get_property_native("user-data/tvh-recording") or nil
    elseif p == "recording_channel" then v = mp.get_property_native("user-data/tvh-recording-channel") or nil
    else v = mp.get_property_native(p) end
    if v == nil then return default end
    return v
end

local function cmd(...)
    local args = { ... }
    if not REMOTE then mp.commandv(unpack(args)); return end
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "/bin/sh", "-c", 'printf "%s\\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1', "sh",
                 utils.format_json({ command = args }), PLAYER_SOCK },
    }, function() end)
end

local function current_index() return get("playlist-pos", 0) + 1 end

local function station_title(i)
    local t
    if REMOTE then t = (remote.titles or {})[i] else t = mp.get_property("playlist/" .. (i - 1) .. "/title") end
    return t or get("media-title", "") or ""
end

local function is_dvb() return get("path", ""):find("/stream/channel/") ~= nil end
local function is_recording() local r = get("recording"); return type(r) == "string" and r ~= "" end

local function is_tuned()
    return not get("core-idle", true) and not get("paused-for-cache", false)
end

local function signal_bars()
    if get("paused-for-cache", false) then return 1 end
    if get("core-idle", true) then return 0 end
    return math.max(1, math.min(5, math.floor(get("demuxer-cache-duration", 0) / 3) + 1))
end

-- Lower line: programme, time left and next (EPG), or the current track
-- of an internet stream. Returns the text and whether it's live data.
local function hms(sec)
    sec = math.floor(sec)
    local h, m, s2 = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    return h > 0 and string.format("%d:%02d:%02d", h, m, s2) or string.format("%d:%02d", m, s2)
end

-- Playing back a Tvheadend recording: where it's from, and the position /
-- length
local function recording_text()
    local pos, dur = get("time-pos"), get("duration")
    local t = (pos and dur and dur > 0) and (hms(pos) .. "/" .. hms(dur)) or (pos and hms(pos) or "")
    local ch = get("recording_channel")
    return (get("pause", false) and "PAUSED" or "PLAYBACK")
        .. ((type(ch) == "string" and ch ~= "") and ("  · FROM " .. ch) or "")
        .. "  · PRESS 1-8 FOR LIVE TV", true, t           -- the pad's channel keys
end

-- TV and radio: the programme on now and the next one, from Tvheadend's
-- EPG, a page at a time: NOW <title> with the time left at the right, then
-- NEXT <title> with its start. A page stays at least PAGE seconds, and
-- long enough for a long title to scroll through once.
local PAGE = 7
local epg_page = { next = false, since = 0, passes = 0 }

local function now_next()
    local now, cur, nxt = os.time(), nil, nil
    for _, e in ipairs(entries or {}) do
        if e.stop and e.stop > now then
            if not cur and e.start and e.start <= now then cur = e
            elseif not nxt and (cur or (e.start or 0) > now) then nxt = e end
        end
    end
    return cur, nxt
end

local function programme_text()
    local cur, nxt = now_next()
    if cur or nxt then
        local t = mp.get_time()
        local passes = scroll_rt.passes or 0
        local moving = scroll_mode == "on" or (scroll_mode == "auto" and mp.get_property_bool("focused", true) ~= false)
        local fits = #scroll_rt.cells <= scroll_rt.cap or not moving
        if t - epg_page.since >= PAGE and (fits or passes > epg_page.passes) then
            epg_page.next, epg_page.since, epg_page.passes = not epg_page.next, t, passes
        end
        local show_next = (epg_page.next and nxt ~= nil) or not cur
        if show_next then
            return "NEXT  " .. (nxt.title or ""), true, "FROM " .. os.date("%H:%M", nxt.start)
        end
        return "NOW  " .. (cur.title or ""), true, fmt_duration(cur.stop - os.time()) .. " LEFT"
    end
    if not is_dvb() then
        local icy = get("metadata/by-key/icy-title", "")
        if icy ~= "" then return icy, true end
        if DEMO and not tvh_host() then return "DEMO  ·  FOR LIVE TV AND RADIO, SET UP TVHEADEND  ·  TVHEADEND.ORG", true end
        return "LIVE STREAM", false
    end
    return "NO PROGRAMME DATA", false
end

-- Tvheadend recording (or about to record) the programme on now or next
local function timer_on()
    local cur, nxt = now_next()
    local function set(e) return e and (e.dvrState == "scheduled" or e.dvrState == "recording") end
    return set(cur) or set(nxt)
end

---------------------------------------------------------------------------
-- Layout, in grid units. Left to right: badge and power, display button
-- group, display, transport keys.
---------------------------------------------------------------------------

local L = {}

local function layout()
    local P = { x = 10, y = 8, w = GW - 20, h = GH - 16 }      -- front panel
    -- Columns shared with the preamp (the same units across): badge 34,
    -- the small buttons 196-300, the display from 330 to GW - 758, then the
    -- transport keys (the preamp's knob) to GW - 34
    local D = { x = 330, y = 26, h = GH - 52 }                 -- display window
    D.w = GW - 758 - D.x
    local pad, prt = 24, 6                                     -- text line pitch
    local nx, aw = D.x + pad, D.w - 2 * pad
    local rt_y = D.y + D.h - 7 * prt - 14
    local name_y = D.y + 40
    local pn = math.min(20, (rt_y - 14 - name_y) / 7,          -- name pitch (as it was
                        aw / (13 * 6 + 5 * 6 * 0.8 + 4))       -- beside a clock)
    scroll_name.cap = math.floor((aw + pn) / (6 * pn))         -- the name: the whole width
    scroll_rt.cap = math.floor((aw + prt) / (6 * prt))

    local buttons = {}
    -- The display group: a column, under the preamp's second one, the
    -- labels on the buttons
    local y0 = (GH - (3 * 30 + 2 * 22)) / 2
    for k, l in ipairs({ "DIM", "COLOUR", "SCROLL" }) do
        buttons[#buttons + 1] = { x = 196, y = y0 + (k - 1) * 52, w = 104, h = 30, r = 15, label = l, small = true }
    end
    local band = TV and "CH" or "TUNE"                         -- transport: tall keys
    local keys = {
        { "PREV", "prev", "◀  " .. band },
        { "NEXT", "next", band .. "  ▶" },
        { "PLAY", "playpause", "PLAY · PAUSE", "play" },
        { "STOP", "stop", "STOP" },
    }                                  -- volume, mute and windows: on the preamp
    local tx0, tg = GW - 712, 14
    local tw = (GW - 34 - tx0 - (#keys - 1) * tg) / #keys
    for k, t in ipairs(keys) do
        buttons[#buttons + 1] = { x = tx0 + (k - 1) * (tw + tg), y = D.y - 4, w = tw, h = D.h - 22, r = 10,
                                  label = t[1], icon = t[2], caption = t[3], led = t[4] }
    end

    L = { P = P, D = D, pad = pad, nx = nx, prt = prt, pn = pn, name_y = name_y, rt_y = rt_y,
          rt_cap = scroll_rt.cap,
          buttons = buttons, power = { x = 52, y = GH - 56, r = 20 } }
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local render

local function cycle_colour()
    local i = 1
    for k, t in ipairs(CYCLE) do if t == theme then i = k end end
    theme = CYCLE[i % #CYCLE + 1]
    FL = DISPLAYS[theme]
    save_prefs()
    notice.text, notice.until_t = "COLOUR  " .. theme, mp.get_time() + 1.6
    render()
end

local function toggle_dim()
    dim_manual = not dim_manual
    save_prefs()
    notice.text, notice.until_t = dim_manual and "DIM  ON" or "DIM  OFF", mp.get_time() + 1.6
    render()
end

-- SCROLL: AUTO (long text scrolls only while the window is active) -> OFF -> ON
local function toggle_scroll()
    scroll_mode = ({ auto = "off", off = "on", on = "auto" })[scroll_mode]
    save_prefs()
    notice.text, notice.until_t = "SCROLL  " .. scroll_mode:upper(), mp.get_time() + 1.6
    render()
end

local function focused() return mp.get_property_bool("focused", true) ~= false end

local function send(sock, ...)                     -- a command to another mpv's socket
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "/bin/sh", "-c", 'printf "%s\\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1', "sh",
                 utils.format_json({ command = { ... } }), sock },
    }, function() end)
end

-- A window's --geometry stretched down to the bottom of the screen, less
-- a 10-point gap (Hammerspoon notes the screen's height in pixels), so the
-- guide opens at its full height straight away
to_bottom = function(o)
    local f = io.open("/tmp/mpv-tvh-screen", "r")
    local sh, scale
    if f then sh, scale = (f:read("*l") or ""):match("^(%d+) (%d+)"); f:close() end
    local w, y0 = o:match("^%-%-geometry=(%d+)x%d+(%+%-?%d+%+(%-?%d+))$")
    local y = y0 and tonumber(o:match("(%-?%d+)$"))
    if not (sh and w and y) then return o end
    local h = tonumber(sh) - y - 10 * tonumber(scale)
    return h > 200 and string.format("--geometry=%sx%d%s", w, h, y0) or o
end

-- The guide window (guide-window.lua), wherever lib-opts puts it
local LIB_SOCK  = "/tmp/mpv-lib-" .. MODE
local LIB_ALIVE = "/tmp/mpv-" .. MODE .. ".lib.alive"
local lib_on, lib_launched, lib_seen = false, 0, false

local function lib_alive()
    local f = io.open(LIB_ALIVE, "r")
    local t = f and tonumber(f:read("*l") or "")
    if f then f:close() end
    return t and os.time() - t <= 3
end

local function toggle_library(want)
    if want == nil then want = not (lib_on and lib_alive()) end   -- closed by its own CLOSE: open
    if want and lib_on and lib_alive() then return end
    lib_on = want
    if lib_on then
        lib_launched, lib_seen = os.time(), false
        if not lib_alive() then
            local args = { "mpv", "--idle=yes", "--force-window=yes", "--osc=no", "--no-border",
                           "--aid=no", "--vid=no", "--sid=no", "--title=Guide",
                           "--window-dragging=no", "--keepaspect-window=no", -- so it can stretch down
                           "--input-ipc-server=" .. LIB_SOCK,
                           "--script-opts-append=tvh-host=" .. (tvh_host() or ""),
                           "--script-opts-append=tvh-demo=" .. (DEMO and not tvh_host() and "1" or "") }
            for _, o in ipairs(LIB_OPTS) do args[#args + 1] = to_bottom(o) end
            mp.command_native_async({ name = "subprocess", args = args, playback_only = false, detach = true },
                function() end)
        end
        do                                     -- Hammerspoon puts it under the stack
            for _, t in ipairs({ 1.5, 3 }) do
                mp.add_timeout(t, function()
                    mp.command_native_async({ name = "subprocess", playback_only = false,
                        args = { "open", "-g", "hammerspoon://tvh-under?kind=lib-" .. MODE } }, function() end)
                end)
            end
        end
    else
        send(LIB_SOCK, "quit")
    end
    render()
end

mp.register_script_message("library-open", function() toggle_library(true) end)
mp.register_script_message("library-close", function() toggle_library(false) end)
mp.register_script_message("guide-setup", function()      -- SETUP on the preamp
    if lib_alive() then send(LIB_SOCK, "script-message", "guide-show", "setup"); return end
    toggle_library(true)
end)

-- List mode: step through the playlist on the display without playing
local LIST_IDLE = 10                   -- seconds before it closes by itself

local function list_open()
    if get("playlist-count", 0) < 1 then return end
    browse = { i = math.max(1, current_index()), until_t = mp.get_time() + LIST_IDLE }
    render()
end

local function list_toggle()
    if browse then browse = nil; render() else list_open() end
end

local function list_move(d)
    local n = get("playlist-count", 0)
    if not browse or n < 1 then return false end
    browse.i = (browse.i - 1 + d) % n + 1
    browse.until_t = mp.get_time() + LIST_IDLE
    render()
    return true
end

local function list_pick()
    if not browse then return false end
    cmd("playlist-play-index", tostring(browse.i - 1))
    browse = nil
    render()
    return true
end

local ACTIONS = {
    PREV   = function()
        if list_move(-1) then return end
        cmd("script-message", "player-prev")    -- the channel before (a recording: back 30 s)
    end,
    NEXT   = function()
        if list_move(1) then return end
        cmd("script-message", "player-next")    -- the next channel (a recording: on 30 s)
    end,
    PLAY   = function() if not list_pick() then cmd("script-message", "player-play") end end,
    MUTE   = function() cmd("cycle", "mute") end,
    FULL   = function() cmd("cycle", "fullscreen") end,
    COLOUR = cycle_colour, DIM = toggle_dim, SCROLL = toggle_scroll,
    STOP   = function() browse = nil; cmd("script-message", "player-stop") end,
    LIB    = function() toggle_library() end,
}

local function power()
    if REMOTE then
        cmd("quit")                                        -- the panel follows the player out
        mp.add_timeout(2, function() mp.command("quit") end)
    else
        mp.command("quit")
    end
end

---------------------------------------------------------------------------
-- Static layer: faceplate, legends, window, buttons (rebuilt on resize)
---------------------------------------------------------------------------

local function hit(id, x, y, w, h, action)
    hits[#hits + 1] = { id = id, x1 = N(x), y1 = N(y), x2 = N(x + w), y2 = N(y + h), action = action }
end

local function build_static(w, h)
    local ev = {}
    hits = {}
    local P, D = L.P, L.D

    -- Body and brushed front panel
    ev[#ev + 1] = shape(rrect_path(P.x, P.y + 8, P.w, P.h, 10), C.plate_lo, 0, 14)
    ev[#ev + 1] = shape(rrect_path(P.x, P.y, P.w, P.h, 10), C.plate_top)
    ev[#ev + 1] = shape(rrect_path(P.x, P.y + 4, P.w, P.h - 4, 10), C.plate)
    local brush = {}
    for i = 0, math.floor((P.h - 20) / 4) do
        brush[#brush + 1] = rect_path(P.x + 12, P.y + 10 + i * 4 + (i * 7 % 3), P.w - 24, 1)
    end
    ev[#ev + 1] = shape(table.concat(brush), C.streak, 247)
    ev[#ev + 1] = shape(rect_path(P.x + 10, P.y + P.h - 3, P.w - 20, 2), C.plate_top, 120)

    -- Badge and power
    ev[#ev + 1] = text(32, 44, 4, 30, C.silk, "mpv-tvh", true, 2)
    ev[#ev + 1] = text(34, 80, 4, 16, C.silk, MODEL, true, 2)
    ev[#ev + 1] = text(34, 102, 4, 11, C.silk_dim, KIND, false, 3)
    local pw = L.power
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y + 3, pw.r), C.plate_lo, 0, 4)
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y, pw.r), C.button_rim)
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y + 1.5, pw.r - 3), C.button)
    ev[#ev + 1] = text(pw.x + pw.r + 14, pw.y + 9, 4, 13, C.silk, "POWER", false, 2)
    ev[#ev + 1] = shape(circle_path(pw.x + pw.r + 20, pw.y - 9, 6), C.led_on, 140, 8)
    ev[#ev + 1] = shape(circle_path(pw.x + pw.r + 20, pw.y - 9, 3.5), C.led_on)
    hit("power", pw.x - pw.r, pw.y - pw.r, 2 * pw.r, 2 * pw.r, power)

    -- Display window
    ev[#ev + 1] = shape(rrect_path(D.x - 8, D.y - 8, D.w + 16, D.h + 16, 8), C.bezel)
    ev[#ev + 1] = shape(rrect_path(D.x - 8, D.y - 8, D.w + 16, 4, 2), "#000000", 60)
    ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), C.window)

    -- Buttons, captions underneath
    for i, b in ipairs(L.buttons) do
        ev[#ev + 1] = shape(rrect_path(b.x, b.y + 2, b.w, b.h, b.r), C.plate_lo)
        ev[#ev + 1] = shape(rrect_path(b.x, b.y, b.w, b.h, b.r), C.button_rim)
        ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button)
        if b.icon then
            local s = math.min(b.w, b.h) * 0.24
            local cx, cy = b.x + b.w / 2, b.y + b.h / 2 + 2
            ev[#ev + 1] = shape(icon_path(b.icon, cx, cy + 1.5, s), C.plate_lo)
            ev[#ev + 1] = shape(icon_path(b.icon, cx, cy, s), b.icon == "rec" and "#FF3B30" or C.silk, 30)
        end
        if b.small then                        -- the small buttons: the label on the button
            ev[#ev + 1] = text(b.x + b.w / 2, b.y + b.h / 2 + 1, 5, 12, C.silk, b.label, false, 2)
        else
            ev[#ev + 1] = text(b.x + b.w / 2, b.y + b.h + 6, 8, 13, C.silk, b.caption or b.label, false, 2)
        end
        local act = ACTIONS[b.label]
        if act then hit("b" .. i, b.x, b.y, b.w, b.h, function()
            if b.label ~= "PLAY" and b.label ~= "NEXT" and b.label ~= "PREV" then browse = nil end
            act()
        end) end
    end
    ev[#ev + 1] = text(L.buttons[1].x, L.buttons[1].y - 8, 1, 12, C.silk_dim, "DISPLAY", false, 3)

    -- The display opens and closes the guide; anywhere else on the panel:
    -- wheel tunes, drag moves the window
    hit("display", D.x, D.y, D.w, D.h, function() toggle_library() end)
    hit("panel", P.x, P.y, P.w, P.h)

    static.w, static.h, static.data = w, h, table.concat(ev, "\n")
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

local function lamp(ev, x, y, label, on)
    ev[#ev + 1] = text(x, y, 4, 13, on and FL[1] or FL[3], label, true, 2)
    return x + (#label * 14 + 30)
end

-- NO SIGNAL: why. Tvheadend recording something (so no tuner free), or
-- not answering. Asked once each time a channel fails.
local nosignal = { asked = false, why = nil }

local function nosignal_reason()
    if not get("nosignal", false) then nosignal.asked, nosignal.why = false, nil; return "" end
    if not nosignal.asked and tvh_host() then
        nosignal.asked = true
        mp.command_native_async({
            name = "subprocess", capture_stdout = true, playback_only = false,
            args = { "curl", "-sS", "--netrc-optional", "--max-time", "4",
                     "http://" .. tvh_host() .. "/api/dvr/entry/grid_upcoming?limit=200" },
        }, function(ok, res)
            local j = ok and res and res.status == 0 and utils.parse_json(res.stdout or "")
            if not j then
                nosignal.why = "CAN'T REACH TVHEADEND"
            else
                for _, e in ipairs(j.entries or {}) do
                    if e.sched_status == "recording" then
                        nosignal.why = "TUNER BUSY: RECORDING " .. ((e.disp_title or e.title or ""):upper())
                            .. ((e.channelname and e.channelname ~= "") and (" ON " .. e.channelname:upper()) or "")
                        break
                    end
                end
                nosignal.why = nosignal.why or "TVHEADEND COULDN'T TUNE IT"
            end
            render()
        end)
    end
    return nosignal.why or (tvh_host() and "ASKING TVHEADEND" or "THE STREAM WON'T OPEN")
end

render = function()
    local w, h = mp.get_osd_size()
    if not w or w == 0 or h == 0 then return end
    if w ~= static.w or h ~= static.h then
        overlay.res_x, overlay.res_y = w, h
        S = h / GH
        GW = GH * w / h
        layout()
        build_static(w, h)
    end

    local ev = { static.data }
    local D = L.D
    local idx = current_index()
    local tuned = is_tuned()
    local muted = get("mute", false)
    local paused = get("pause", false)
    local chans = tuned and get("audio-params/channel-count", 0) or 0
    local rec = is_recording()
    local rt, live, fixed
    if rec then rt, live, fixed = recording_text()
    else rt, live, fixed = programme_text() end
    local programme_rt = rt
    local name = rec and get("recording") or station_title(idx)
    local empty = (get("playlist-count", 0) or 0) == 0 and not rec   -- no channels on the keys yet
    if empty then
        name = TV and "NO CHANNELS" or "NO STATIONS"
        rt, live, fixed = "CLICK HERE OR PRESS GUIDE TO PICK " .. (TV and "SOME CHANNELS" or "SOME STATIONS"), true, nil
        programme_rt = rt
    end
    if get("stopped", false) and not empty then                   -- STOP
        local si = get("stopped_index", 0) or 0
        if si > 0 then name = station_title(si) end
        rt, live = "STOPPED  ·  PRESS PLAY", false
        if get("nosignal", false) then
            rt, live = "NO SIGNAL  ·  " .. nosignal_reason() .. "  ·  PRESS PLAY TO TRY AGAIN", true
        end
    end
    do                                         -- from the player: switched to the channel recording
        local pn = get("player_notice")
        if type(pn) == "table" and pn.t and os.time() - pn.t < 25 then   -- long enough to scroll through
            rt, live = pn.text or "", true
        end
    end
    if browse and mp.get_time() > browse.until_t then browse = nil end
    if browse then
        name = station_title(browse.i)
        rt = string.format("%d/%d  %s", browse.i, get("playlist-count", 0),
            browse.i == idx and "PLAYING NOW" or "PRESS PLAY")
        live, fixed = true, ""
    end
    if notice.text and mp.get_time() < notice.until_t then rt, live = notice.text, true end
    if rt ~= programme_rt then fixed = nil end                   -- STOP, notices

    -- Indicator lamps
    local iy = D.y + 18
    local x = D.x + L.pad
    local loaded = get("path", "") ~= ""               -- stopped: neither
    x = lamp(ev, x, iy, "DVB", loaded and is_dvb())
    x = lamp(ev, x, iy, rec and "PVR" or "NET", loaded and (rec or not is_dvb()))
    if TV then
        x = lamp(ev, x, iy, "HD", tuned and get("video-params/h", 0) >= 720)
        x = lamp(ev, x, iy, "16:9", tuned and get("video-params/aspect", 0) > 1.5)
        x = lamp(ev, x, iy, chans > 2 and "5.1" or "STEREO", chans >= 2)
        x = lamp(ev, x, iy, "SUBS", get("sub-visibility", false) and type(get("sid")) == "number")
        x = lamp(ev, x, iy, "EPG", entries ~= nil and entries[1] ~= nil)
        x = lamp(ev, x, iy, "TIMER", timer_on())
    else
        x = lamp(ev, x, iy, "TUNED", tuned)
        x = lamp(ev, x, iy, "STEREO", chans >= 2)
        x = lamp(ev, x, iy, "RDS", live and not empty)
        x = lamp(ev, x, iy, "TIMER", timer_on())
    end
    x = lamp(ev, x, iy, "MUTE", muted)
    x = lamp(ev, x, iy, "PAUSE", paused)
    x = (idx > 0 and not rec or browse) and lamp(ev, x, iy, string.format("P%02d", browse and browse.i or idx), true) or x
    if browse then lamp(ev, x, iy, "LIST", true) end

    -- Signal meter
    local bars, lit, off = signal_bars(), {}, {}
    local x0 = D.x + D.w - L.pad - 5 * 26 + 6
    for i = 1, 5 do
        local path = rect_path(x0 + (i - 1) * 26, iy + 7 - i * 4, 20, 4 + i * 4)
        if i <= bars then lit[#lit + 1] = path else off[#off + 1] = path end
    end
    if #off > 0 then ev[#ev + 1] = shape(table.concat(off), FL[3]) end
    if #lit > 0 then
        ev[#ev + 1] = shape(table.concat(lit), FL[1], 150, 6)
        ev[#ev + 1] = shape(table.concat(lit), FL[1])
    end
    ev[#ev + 1] = text(x0 - 14, iy, 6, 15, bars > 0 and FL[2] or FL[3], "SIG", true, 2)

    -- Station name, programme line
    scroll_set(scroll_name, name)
    draw_matrix(ev, L.nx, L.name_y, scroll_name.cap, L.pn, scroll_view(scroll_name), FL[1], true)
    local fw = rec and 15 or 10                          -- a recording's position / length; time left
    scroll_rt.cap = L.rt_cap - (((fixed or "") ~= "") and (fw + 1) or 0)
    scroll_set(scroll_rt, rt)
    draw_matrix(ev, L.nx, L.rt_y, scroll_rt.cap, L.prt, scroll_view(scroll_rt), live and FL[1] or FL[2], live)
    if (fixed or "") ~= "" then              -- position / length, or time left, right of the text
        draw_matrix(ev, L.nx + (scroll_rt.cap + 1) * 6 * L.prt, L.rt_y, fw, L.prt,
            cells(string.format("%" .. fw .. "s", fixed or "")), FL[2], false)
    end

    -- The LED on the PLAY key
    for _, b in ipairs(L.buttons) do
        if b.led then
            local on = (b.led == "play" and not paused)
            if browse and b.label == "PLAY" then on = math.floor(mp.get_time() * 3) % 2 == 0 end
            local lx, ly = b.x + b.w - 16, b.y + 16
            local lc = C.led_on
            if on then ev[#ev + 1] = shape(circle_path(lx, ly, 6), lc, 140, 8) end
            ev[#ev + 1] = shape(circle_path(lx, ly, 3.5), on and lc or C.led_off)
        end
    end

    -- Dimmer: manual, or whenever the window isn't the active one
    if dim_manual or not focused() then
        ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), "#000000", 255 - DIM_ALPHA)
    end

    -- Button being pressed
    if pressed.id and mp.get_time() < pressed.until_t then
        for i, b in ipairs(L.buttons) do
            if pressed.id == "b" .. i then
                ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button_dn)
            end
        end
    end

    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

---------------------------------------------------------------------------
-- EPG
---------------------------------------------------------------------------

local boundary_timer                   -- fetch again when the programme on now ends

local function fetch()
    local uuid = get("path", ""):match("/stream/channel/(%w+)")
    if not uuid or not tvh_host() then entries = nil; render(); return end   -- internet stream: no EPG

    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "curl", "-sS", "--max-time", "3",
            string.format("http://%s/api/epg/events/grid?limit=3&sort=start&dir=ASC&channel=%s", tvh_host(), uuid) },
    }, function(success, result)
        if success and result and result.status == 0 then
            local parsed = utils.parse_json(result.stdout or "")
            entries = parsed and parsed.entries or nil
        end
        if boundary_timer then boundary_timer:kill(); boundary_timer = nil end
        local e = entries and entries[1]
        if e and e.stop and e.stop > os.time() then
            boundary_timer = mp.add_timeout(e.stop - os.time() + 3, fetch)
        end
        render()
    end)
end

---------------------------------------------------------------------------
-- Mouse and keys
---------------------------------------------------------------------------

local function hit_at()
    local m = mp.get_property_native("mouse-pos") or {}
    local mx, my = m.x or -1, m.y or -1
    for _, a in ipairs(hits) do
        if mx >= a.x1 and mx <= a.x2 and my >= a.y1 and my <= a.y2 then return a end
    end
end

mp.add_forced_key_binding("MBTN_LEFT", "faceplate-click", function(e)
    if e.event ~= "down" then return end
    local a = hit_at()
    if a and a.action then
        pressed.id, pressed.until_t = a.id, mp.get_time() + 0.15
        a.action()
        render()
        mp.add_timeout(0.16, render)
    else
        pcall(mp.commandv, "begin-vo-dragging")         -- drag the window (mpv 0.38+)
    end
end, { complex = true })

-- Scroll over the panel to tune (throttled: trackpads send bursts)
local last_wheel = 0
local function wheel(dir)
    return function()
        if not hit_at() then return end
        local now = mp.get_time()
        if now - last_wheel < 0.25 then return end
        last_wheel = now
        if not list_move(dir) then cmd(dir > 0 and "playlist-next" or "playlist-prev") end
    end
end
mp.add_forced_key_binding("WHEEL_UP", "faceplate-tune-up", wheel(-1))
mp.add_forced_key_binding("WHEEL_DOWN", "faceplate-tune-down", wheel(1))

mp.register_script_message("radio-colour", cycle_colour)
-- From the preamp (the pad's layer 3): display-set colour <name> | dim on|off | scroll <mode>
mp.register_script_message("display-set", function(what, v)
    if what == "colour" and DISPLAYS[v or ""] then theme = v; FL = DISPLAYS[v]
    elseif what == "dim" then dim_manual = v == "on"
    elseif what == "scroll" and ({ auto = 1, off = 1, on = 1 })[v or ""] then scroll_mode = v
    else return end
    save_prefs()
    render()
end)
mp.register_script_message("radio-dim", toggle_dim)
mp.register_script_message("radio-scroll", toggle_scroll)

-- From the preamp's GUIDE button: window-toggle library
mp.register_script_message("window-toggle", function(which)
    if which == "library" then toggle_library() end
end)

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

-- A double-click would make the faceplate full screen: ignore it
mp.commandv("keybind", "MBTN_LEFT_DBL", "ignore")

-- The faceplate has its own buttons, so keep mpv's OSC hidden
local function hide_osc()
    mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
end

for _, p in ipairs({ "osd-dimensions", "focused" }) do
    mp.observe_property(p, "native", function() render() end)
end

if REMOTE then
    -- Follow the player's published state; close when it goes
    local started, last_raw, last_path = os.time(), nil, nil
    hide_osc()
    mp.add_periodic_timer(0.25, function()
        local f = io.open(PLAYER_STATE, "r")
        local raw = f and f:read("*a")
        if f then f:close() end
        if raw and raw ~= last_raw then
            local s = utils.parse_json(raw)
            if s and (s.t or 0) >= started - 2 then          -- ignore a previous session's file
                last_raw, remote = raw, s
                if s.closed then mp.command("quit"); return end
                if s.path ~= last_path then
                    last_path = s.path; entries = nil; fetch()
                end
                render()
            end
        end
        local age = os.time() - (remote.t or started)
        if age > (remote.t and 6 or 30) then mp.command("quit") end   -- player gone or never started
    end)

    -- Pad keys and knob act on the player even while the panel has focus
    local function fwd(key, ...)
        local a = { ... }
        PAD[key] = function() cmd(unpack(a)) end
        mp.add_forced_key_binding(key, "panel-" .. key, PAD[key])
    end
    for i = 1, 8 do fwd("F" .. (12 + i), "playlist-play-index", tostring(i - 1)) end
else
    mp.register_event("file-loaded", function()
        hide_osc()
        entries = nil
        render()
        fetch()
    end)
    for _, p in ipairs({ "pause", "mute", "core-idle", "paused-for-cache", "media-title", "playlist-pos",
                         "metadata/by-key/icy-title", "audio-params/channel-count" }) do
        mp.observe_property(p, "native", function() render() end)
    end
end

-- The guide closed by hand (or opened before)?
mp.add_periodic_timer(1, function()
    local alive = lib_alive() == true
    if alive then lib_seen = true end
    -- once it's been up, a missing heartbeat means it's closed (it removes
    -- it as it goes); while starting, give it 8 seconds
    if (lib_seen or os.time() - lib_launched > 8) and lib_on ~= alive then
        lib_on = not lib_on
        render()
    end
end)

-- Knob 1 and Enter: list mode first, then the usual pause / seek / step
local function key(name, fn)
    PAD[name] = fn
    mp.add_forced_key_binding(name, "faceplate-" .. name, fn)
end
key("ENTER", function() if not list_pick() then cmd("script-message", "player-play") end end)
key("ESC", function() browse = nil; render() end)
key("Alt+ENTER", list_toggle)
key("Alt+UP", function() if not list_move(-1) then cmd("script-message", "player-prev") end end)
key("Alt+DOWN", function() if not list_move(1) then cmd("script-message", "player-next") end end)
key("UP", function() if not list_move(-1) then cmd("seek", "-5") end end)
key("DOWN", function() if not list_move(1) then cmd("seek", "5") end end)

-- The pad, from Hammerspoon: script-message pad-key <key> does what that key
-- does in this window, wherever the focus is (the preamp's chosen source)
if not REMOTE then                                     -- the radio: its keys are input.conf's
    for i = 1, 8 do PAD["F" .. (12 + i)] = function() cmd("playlist-play-index", tostring(i - 1)) end end
end
PAD["GUIDE"] = function() toggle_library() end         -- the pad's GUIDE key
-- The pad's layer 2 (Hammerspoon): the transport keys, full screen, recordings
for _, name in ipairs({ "PREV", "NEXT", "PLAY", "STOP" }) do PAD[name] = ACTIONS[name] end
PAD["FULL"] = function() if TV then cmd("cycle", "fullscreen") end end
PAD["RECORDINGS"] = function()                           -- the guide, on its recordings
    if lib_on and lib_alive() then send(LIB_SOCK, "script-message", "guide-show", "recs"); return end
    toggle_library(true)
    mp.add_timeout(1.5, function() send(LIB_SOCK, "script-message", "guide-show", "recs") end)
end
mp.register_script_message("pad-key", function(name)
    local fn = PAD[name or ""]
    if fn then fn(); render() end
end)

mp.add_periodic_timer(REFRESH, fetch)
mp.add_periodic_timer(1, render)                       -- time left, signal, notices
mp.add_periodic_timer(0.08, function()                 -- scrolling text
    local now = mp.get_time()
    local moving = scroll_mode == "on" or (scroll_mode == "auto" and focused())
    local changed = false
    for _, sc in ipairs({ scroll_name, scroll_rt }) do
        if moving then
            changed = scroll_tick(sc, now) or changed
        elseif sc.pos ~= 0 then                        -- stopped: back to the start
            sc.pos, sc.next_t, changed = 0, now + HOLD, true
        end
    end
    if changed then render() end
end)
