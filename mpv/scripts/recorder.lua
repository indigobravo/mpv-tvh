-- recorder.lua
-- The RC-252 recorder: a media-less mpv window (control socket
-- /tmp/mpv-recorder, started by `recorder`) at the bottom of the stack. It
-- records the source chosen with the preamp's REC OUT selector (which can
-- differ from the one you're listening to): REC asks that player to write
-- the stream it receives to a file (mpv's stream-record), as sent, with no
-- re-encoding. Changing the preamp's input doesn't touch the recording;
-- changing REC OUT carries on recording from the new source, in a new file.
--
--   Files go in <music folder>/recordings/<station>/, named with the date,
--   time and the track or programme (script-opt rec-dir). SPLIT starts a new
--   file whenever the station's track title changes; NEW FILE does it now.
--   FOLDER shows the recordings in Finder. STOP or POWER ends the file.
--
-- It reads the REC OUT choice from /tmp/mpv-preamp.rec and the sources'
-- state from /tmp/mpv-<kind>.state.json, and writes what it's doing to
-- /tmp/mpv-recorder.state for the preamp's REC lamp.

local mp = require 'mp'
local utils = require 'mp.utils'

if not (mp.get_property("input-ipc-server") or ""):match("/mpv%-recorder$") then return end

local SOURCES = {
    tv    = { kind = "tv",      label = "TV" },
    tuner = { kind = "radio",   label = "TUNER" },
    net   = { kind = "youtube", label = "NET" },
}
local ORDER = { "tv", "tuner", "net" }
local REC_FILE   = "/tmp/mpv-preamp.rec"
local STATE_FILE = "/tmp/mpv-recorder.state"
local PREFS_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-recorder-prefs" })
local REC_DIR = mp.get_opt("rec-dir") or ""
if REC_DIR == "" then REC_DIR = mp.command_native({ "expand-path", "~/Music/recordings" }) end

local DISPLAYS = {
    blue  = { "#9FE8FF", "#4E8FA6", "#0B171B" },
    red   = { "#FF5A47", "#9A3326", "#1C0C0A" },
    green = { "#7DFFB0", "#3E9A66", "#0A1912" },
    amber = { "#FFB347", "#A06A22", "#1C1409" },
}
local CYCLE = { "red", "amber", "green", "blue" }
local C = {
    plate = "#0E0E10", plate_top = "#1C1C20", plate_lo = "#030304", streak = "#FFFFFF",
    silk = "#C9C9CE", silk_dim = "#707078", window = "#030506", bezel = "#1A1A1D",
    button = "#18181B", button_rim = "#3A3A40", button_dn = "#0B0B0D",
    led_on = "#3DDC84", led_off = "#1B1D1C", rec = "#FF3B30",
}
local FONT = "Helvetica Neue"
local DIM_ALPHA = 77

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
local colour = DISPLAYS[prefs.colour or ""] and prefs.colour or "red"
local split = prefs.split == "on"
local dim_manual = prefs.dim == "on"
local scroll_mode = ({ auto = 1, off = 1, on = 1 })[prefs.scroll or ""] and prefs.scroll or "auto"

local function save_prefs()
    local f = io.open(PREFS_FILE, "w")
    if not f then return end
    f:write("colour=", colour, "\n", "split=", split and "on" or "off", "\n",
            "dim=", dim_manual and "on" or "off", "\n", "scroll=", scroll_mode, "\n")
    f:close()
end

---------------------------------------------------------------------------
-- Drawing helpers (as preamp.lua)
---------------------------------------------------------------------------

local GH = 240                         -- a faceplate's height
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
local hits = {}
local pressed = { id = nil, until_t = 0 }
local notice = { text = nil, until_t = 0 }
local rec = nil                        -- recording: { id, path, title, start, file_start, files }
local rec_out = nil                    -- the preamp's REC OUT choice
local sources = {}                     -- id -> latest state, while running
local scrolls = { top = { cells = {}, pos = 0, next_t = 0 }, low = { cells = {}, pos = 0, next_t = 0 } }
FL = DISPLAYS[colour]

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


local function say(s, secs)
    notice.text, notice.until_t = s, mp.get_time() + (secs or 2.5)
end

local function write_state()
    local f = io.open(STATE_FILE, "w")
    if f then f:write(rec and ("rec " .. rec.id) or "idle", "\n", os.time(), "\n"); f:close() end
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------

local function read_state(id)
    local f = io.open("/tmp/mpv-" .. SOURCES[id].kind .. ".state.json", "r")
    local raw = f and f:read("*a")
    if f then f:close() end
    local s = raw and utils.parse_json(raw)
    if s and not s.closed and os.time() - (s.t or 0) <= 6 then return s end
end

local function read_rec_out()
    local f = io.open(REC_FILE, "r")
    local id = f and f:read("*l")
    if f then f:close() end
    return SOURCES[id or ""] and id or nil
end

-- The station, and the track or programme, for naming files
local function station_of(st)
    local pos = (st["playlist-pos"] or -1) + 1
    return (st.titles or {})[pos] or st["media-title"] or "Unknown"
end

local function track_of(id, st)
    if id == "tuner" then
        local icy = st["metadata/by-key/icy-title"]
        return (icy and icy ~= "") and icy or nil
    elseif id == "net" then
        return st["media-title"]
    end
    return nil
end

local function clean(s)
    s = (s or ""):gsub("[/:%c\\]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 100 then s = s:sub(1, 100):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") end
    return s
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local function new_path(id, st)
    local dir = REC_DIR .. "/" .. clean(station_of(st))
    utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false })
    local track = track_of(id, st)
    local name = os.date("%Y-%m-%d %H.%M.%S") .. (track and (" " .. clean(track)) or "")
    local video = st.vid ~= nil and st.vid ~= false and st.vid ~= "no"
    return dir .. "/" .. name .. (video and ".mkv" or ".mka")
end

local render

local function start_file(id, st, reason)
    local path = new_path(id, st)
    send("/tmp/mpv-" .. SOURCES[id].kind, "set", "stream-record", path)
    local files = rec and rec.id == id and rec.files or 0
    rec = { id = id, path = path, title = track_of(id, st), station = station_of(st),
            start = rec and rec.id == id and rec.start or os.time(), file_start = os.time(),
            files = files + 1 }
    write_state()
    if reason then say(reason) end
end

local function stop(reason)
    if not rec then return end
    send("/tmp/mpv-" .. SOURCES[rec.id].kind, "set", "stream-record", "")
    rec = nil
    write_state()
    say(reason or "STOPPED", 3)
end

local function record()
    if rec then return end
    rec_out = read_rec_out()
    if not rec_out then say("CHOOSE A SOURCE WITH REC OUT ON THE PREAMP", 4); render(); return end
    local st = read_state(rec_out)
    if not st then say(SOURCES[rec_out].label .. " ISN'T PLAYING", 3); render(); return end
    start_file(rec_out, st, "RECORDING")
    render()
end

local function new_file()
    if not rec then return end
    local st = read_state(rec.id)
    if st then start_file(rec.id, st, "NEW FILE") end
    render()
end

-- Every half second: follow REC OUT, the source, and (SPLIT) its titles
mp.add_periodic_timer(0.5, function()
    for _, id in ipairs(ORDER) do sources[id] = read_state(id) end
    rec_out = read_rec_out()
    if rec then
        local st = sources[rec.id]
        if not st then
            stop("SOURCE STOPPED")
        elseif not rec_out then
            stop("REC OUT OFF")
        elseif rec_out and rec_out ~= rec.id then     -- REC OUT changed: carry on from there
            local new = sources[rec_out]
            send("/tmp/mpv-" .. SOURCES[rec.id].kind, "set", "stream-record", "")
            if new then
                rec.files = 0
                rec.start = os.time()
                start_file(rec_out, new, "NOW RECORDING " .. SOURCES[rec_out].label)
            else
                rec = nil
                write_state()
                say(SOURCES[rec_out].label .. " ISN'T PLAYING", 3)
            end
        elseif split and track_of(rec.id, st) and track_of(rec.id, st) ~= rec.title then
            start_file(rec.id, st, "NEW TRACK")
        end
    end
    render()
end)

---------------------------------------------------------------------------
-- Layout and drawing
---------------------------------------------------------------------------

local L = {}
local function layout()
    local P = { x = 10, y = 8, w = GW - 20, h = GH - 16 }
    local gx0, gx1 = 196, 452
    local D = { x = gx1 + 44, y = 26, h = GH - 52 }
    D.w = GW - D.x - 680 - 78
    local buttons = {}
    local gw = (gx1 - gx0 - 28) / 3
    for k, l in ipairs({ "SPLIT", "DIM", "SCROLL", "FOLDER", "COLOUR" }) do
        local r, c = math.floor((k - 1) / 3), (k - 1) % 3
        buttons[#buttons + 1] = { x = gx0 + c * (gw + 14), y = r == 0 and 44 or GH - 96, w = gw, h = 30, r = 15,
                                  label = l, led = l == "SPLIT" }
    end
    local keys = { { "REC", "rec", "REC" }, { "STOP", "stop", "STOP" }, { "NEWFILE", "newfile", "NEW FILE" } }
    local tx0, tg = D.x + D.w + 46, 14
    local tw = (GW - 34 - tx0 - (#keys - 1) * tg) / #keys
    for k, t in ipairs(keys) do
        buttons[#buttons + 1] = { x = tx0 + (k - 1) * (tw + tg), y = D.y - 4, w = tw, h = D.h - 22, r = 10,
                                  label = t[1], icon = t[2], caption = t[3] }
    end
    local pad, prt = 24, 6
    local rt_y = D.y + D.h - 7 * prt - 14
    local name_y = D.y + 40
    local pn = math.min(20, (rt_y - 14 - name_y) / 7, (D.w - 2 * pad) / (13 * 6 + 8 * 6 * 0.8 + 4))
    L = { P = P, D = D, buttons = buttons, pad = pad, prt = prt, pn = pn, cp = pn * 0.8,
          rt_y = rt_y, name_y = name_y, power = { x = 52, y = GH - 56, r = 20 } }
end

local function hit(id, x, y, w, h, action)
    hits[#hits + 1] = { id = id, x1 = N(x), y1 = N(y), x2 = N(x + w), y2 = N(y + h), action = action }
end

local function rec_icon(kind, cx, cy, s)
    if kind == "rec" then return circle_path(cx, cy, 0.5 * s) end
    if kind == "stop" then return rect_path(cx - 0.5 * s, cy - 0.5 * s, s, s) end
    -- new file: a page with a folded corner
    local w, h, k = 0.8 * s, 1.1 * s, 0.3 * s
    return poly_path({ cx - w / 2, cy - h / 2, cx + w / 2 - k, cy - h / 2, cx + w / 2, cy - h / 2 + k,
                       cx + w / 2, cy + h / 2, cx - w / 2, cy + h / 2 })
end

local ACTIONS
local static = { w = 0, h = 0 }

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
    ev[#ev + 1] = text(34, 80, 4, 16, C.silk, "RC-252", true, 2)
    ev[#ev + 1] = text(34, 102, 4, 11, C.silk_dim, "STREAM RECORDER", false, 3)
    local pw = L.power
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y + 3, pw.r), C.plate_lo, 0, 4)
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y, pw.r), C.button_rim)
    ev[#ev + 1] = shape(circle_path(pw.x, pw.y + 1.5, pw.r - 3), C.button)
    ev[#ev + 1] = text(pw.x + pw.r + 14, pw.y + 9, 4, 13, C.silk, "POWER", false, 2)
    ev[#ev + 1] = shape(circle_path(pw.x + pw.r + 20, pw.y - 9, 6), C.led_on, 140, 8)
    ev[#ev + 1] = shape(circle_path(pw.x + pw.r + 20, pw.y - 9, 3.5), C.led_on)
    hit("power", pw.x - pw.r, pw.y - pw.r, 2 * pw.r, 2 * pw.r, function()
        stop()
        mp.add_timeout(0.3, function() mp.command("quit") end)
    end)

    ev[#ev + 1] = shape(rrect_path(D.x - 8, D.y - 8, D.w + 16, D.h + 16, 8), C.bezel)
    ev[#ev + 1] = shape(rrect_path(D.x - 8, D.y - 8, D.w + 16, 4, 2), "#000000", 60)
    ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), C.window)

    for i, b in ipairs(L.buttons) do
        ev[#ev + 1] = shape(rrect_path(b.x, b.y + 2, b.w, b.h, b.r), C.plate_lo)
        ev[#ev + 1] = shape(rrect_path(b.x, b.y, b.w, b.h, b.r), C.button_rim)
        ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button)
        if b.icon then
            local s, cx, cy = math.min(b.w, b.h) * 0.24, b.x + b.w / 2, b.y + b.h / 2 + 2
            ev[#ev + 1] = shape(rec_icon(b.icon, cx, cy + 1.5, s), C.plate_lo)
            ev[#ev + 1] = shape(rec_icon(b.icon, cx, cy, s), b.icon == "rec" and C.rec or C.silk, 30)
        end
        ev[#ev + 1] = text(b.x + b.w / 2, b.y + b.h + 6, 8, 13, C.silk, b.caption or b.label, false, 2)
        hit("b" .. i, b.x, b.y, b.w, b.h, ACTIONS[b.label])
    end
    ev[#ev + 1] = text(L.buttons[1].x, L.buttons[1].y - 8, 1, 12, C.silk_dim, "DISPLAY", false, 3)
    hit("panel", P.x, P.y, P.w, P.h)
    backdrop.data = table.concat(ev, "\n")
    backdrop:update()
end

local function lamp(ev, x, y, label, level)
    ev[#ev + 1] = text(x, y, 4, 13, level == 2 and FL[1] or level == 1 and FL[2] or FL[3], label, true, 2,
        level == 2 and 0.6 or 0)
    return x + (#label * 14 + 30)
end

local function hms(sec)
    sec = math.max(0, math.floor(sec))
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    return h > 0 and string.format("%d:%02d:%02d", h, m, s) or string.format("%d:%02d", m, s)
end

local function size_of(path)
    local info = path and utils.file_info(path)
    local b = info and info.size or 0
    if b >= 1e9 then return string.format("%.2fGB", b / 1e9) end
    if b >= 1e6 then return string.format("%.1fMB", b / 1e6) end
    return string.format("%dKB", math.floor(b / 1e3))
end

-- A field of n cells that scrolls when the text is longer (SCROLL: AUTO
-- only while the window is active, OFF never, ON always)
local function scrolled(sc, text_, n, now)
    if text_ ~= sc.text then sc.text, sc.cells, sc.pos, sc.next_t = text_, cells(text_), 0, now + 2.5 end
    if #sc.cells <= n then return sc.cells end
    local moving = scroll_mode == "on"
        or (scroll_mode == "auto" and mp.get_property_bool("focused", true) ~= false)
    if not moving then sc.pos = 0 end
    if moving and now >= sc.next_t then
        sc.pos = (sc.pos + 1) % (#sc.cells + 4)
        sc.next_t = now + (sc.pos == 0 and 2.5 or 0.32)
    end
    local out = {}
    for i = 1, n do
        local k = (sc.pos + i - 1) % (#sc.cells + 4) + 1
        out[i] = sc.cells[k] or " "
    end
    return out
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
    local ev, D, now = {}, L.D, mp.get_time()
    local blink = math.floor(now * 2) % 2 == 0

    -- Lamps: REC (blinking), the REC OUT source, SPLIT, files this take
    local x, iy = D.x + L.pad, D.y + 18
    if rec then
        ev[#ev + 1] = shape(circle_path(x + 6, iy, 6), C.rec, blink and 0 or 200, 0)
        if blink then ev[#ev + 1] = shape(circle_path(x + 6, iy, 11), C.rec, 150, 8) end
    else
        ev[#ev + 1] = shape(circle_path(x + 6, iy, 6), FL[3])
    end
    x = lamp(ev, x + 22, iy, "REC", rec and 2 or 0)
    for _, id in ipairs(ORDER) do
        x = lamp(ev, x, iy, SOURCES[id].label, id == (rec and rec.id or rec_out) and 2 or (sources[id] and 1 or 0))
    end
    x = lamp(ev, x + 10, iy, "SPLIT", split and 2 or 0)
    if rec and rec.files > 1 then lamp(ev, x, iy, string.format("FILE %02d", rec.files), 2) end

    -- Big line: what's being recorded, and the time on this file
    local big, right
    if rec then
        big = rec.title and (rec.station .. "  · " .. rec.title) or rec.station
        right = hms(os.time() - rec.file_start)
    else
        local st = rec_out and sources[rec_out]
        big = st and ("READY  · " .. station_of(st)) or (rec_out and (SOURCES[rec_out].label .. " OFF") or "NO REC OUT")
        right = os.date("%H:%M")
    end
    local rcells = 7
    local cap = math.floor((D.w - 2 * L.pad - rcells * 6 * L.cp - 20) / (6 * L.pn))
    draw_matrix(ev, D.x + L.pad, L.name_y, cap, L.pn, scrolled(scrolls.top, big, cap, now), FL[1], rec ~= nil)
    draw_matrix(ev, D.x + D.w - L.pad - (rcells * 6 - 1) * L.cp, L.name_y + (7 * L.pn - 7 * L.cp) / 2, rcells, L.cp,
        rpad(right, rcells), rec and FL[1] or FL[2], rec ~= nil)

    -- Lower line: notice, or the file and its size
    local low, fixed
    if notice.text and now < notice.until_t then
        low, fixed = notice.text, ""
    elseif rec then
        low, fixed = rec.path:match("([^/]+)$") or "", size_of(rec.path)
    else
        local home = os.getenv("HOME") or ""
        local where = (home ~= "" and REC_DIR:sub(1, #home) == home) and ("~" .. REC_DIR:sub(#home + 1)) or REC_DIR
        low, fixed = "PRESS REC  · FILES GO TO " .. where, ""
    end
    local fcells = 9
    local lcap = math.floor((D.w - 2 * L.pad) / (6 * L.prt)) - fcells - 1
    draw_matrix(ev, D.x + L.pad, L.rt_y, lcap, L.prt, scrolled(scrolls.low, low, lcap, now), FL[2], false)
    draw_matrix(ev, D.x + D.w - L.pad - (fcells * 6 - 1) * L.prt, L.rt_y, fcells, L.prt, rpad(fixed, fcells), FL[2], false)

    -- LEDs: SPLIT; REC key lit while recording
    for i, b in ipairs(L.buttons) do
        if b.led then
            local lx, ly = b.x + b.w - 16, b.y + b.h / 2
            if split then ev[#ev + 1] = shape(circle_path(lx, ly, 6), C.led_on, 140, 8) end
            ev[#ev + 1] = shape(circle_path(lx, ly, 3.5), split and C.led_on or C.led_off)
        elseif b.label == "REC" then
            local lx, ly = b.x + b.w - 16, b.y + 16
            if rec then ev[#ev + 1] = shape(circle_path(lx, ly, 6), C.rec, 140, 8) end
            ev[#ev + 1] = shape(circle_path(lx, ly, 3.5), rec and C.rec or C.led_off)
        end
        if pressed.id == "b" .. i and now < pressed.until_t then
            ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 2, b.w - 3, b.h - 3.5, b.r - 1.5), C.button_dn)
        end
    end

    if dim_manual or mp.get_property_bool("focused", true) == false then
        ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), "#000000", 255 - DIM_ALPHA)
    end
    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

ACTIONS = {
    REC     = record,
    STOP    = function() stop() end,
    NEWFILE = new_file,
    SPLIT   = function() split = not split; save_prefs(); say(split and "SPLIT ON TRACK CHANGES" or "SPLIT OFF") end,
    DIM     = function() dim_manual = not dim_manual; save_prefs() end,
    SCROLL  = function()
        scroll_mode = ({ auto = "off", off = "on", on = "auto" })[scroll_mode]
        save_prefs()
        say("SCROLL  " .. scroll_mode:upper(), 1.6)
    end,
    FOLDER  = function()
        utils.subprocess({ args = { "mkdir", "-p", REC_DIR }, cancellable = false })
        mp.command_native_async({ name = "subprocess", playback_only = false, args = { "open", REC_DIR } },
            function() end)
    end,
    COLOUR  = function()
        local i = 1
        for k, c in ipairs(CYCLE) do if c == colour then i = k end end
        colour = CYCLE[i % #CYCLE + 1]
        FL = DISPLAYS[colour]
        save_prefs()
    end,
}

---------------------------------------------------------------------------
-- Mouse and wiring
---------------------------------------------------------------------------

local function hit_at()
    local m = mp.get_property_native("mouse-pos") or {}
    local mx, my = m.x or -1, m.y or -1
    for _, a in ipairs(hits) do
        if mx >= a.x1 and mx <= a.x2 and my >= a.y1 and my <= a.y2 then return a end
    end
end

mp.add_forced_key_binding("MBTN_LEFT", "recorder-click", function(e)
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

mp.register_script_message("recorder-rec", record)
mp.register_script_message("recorder-stop", function() stop() end)

-- Smooth scrolling and the blinking lamp while recording
mp.add_periodic_timer(0.16, function() if rec then render() end end)

mp.register_event("shutdown", function()
    if rec then send_now("/tmp/mpv-" .. SOURCES[rec.id].kind, "set", "stream-record", "") end
    rec = nil
    write_state()
end)

do
    local dir = PREFS_FILE:match("(.*)/")
    if dir then utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false }) end
end
mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
mp.observe_property("osd-dimensions", "native", function() render() end)
mp.observe_property("focused", "native", function() render() end)
write_state()
