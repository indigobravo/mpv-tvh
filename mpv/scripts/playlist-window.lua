-- playlist-window.lua
-- The CD player's playlist (control socket /tmp/mpv-list-music) and
-- YouTube's (/tmp/mpv-list-youtube): their own media-less mpv window,
-- opened and closed by the preamp's PLAYLIST button (through the
-- faceplate) and drawn on the same brushed-black front as the faceplates.
--
--   A table of the queue: number, title, album (its folder) and length,
--   the track playing lit, the ones played dimmed. Double-click a track to
--   play it, drag it to move it, × removes it, scroll for more (it follows
--   the track playing). Drop music files or folders on the window to add
--   them (folders are searched for music, in name order). CLEAR removes
--   everything but the track playing. YouTube's lists its links (with the
--   recent ones) with each video's channel and length (from yt-dlp); drop
--   or paste links to queue them.
--
-- It reads the player's state from /tmp/mpv-music.state.json (written by
-- player-state.lua) and sends it commands over /tmp/mpv-music with nc. It
-- writes /tmp/mpv-music.list.alive while open, follows the faceplate's
-- display colour, and closes when the player quits.

local mp = require 'mp'
local utils = require 'mp.utils'

local KIND = (mp.get_property("input-ipc-server") or ""):match("/mpv%-list%-(%a+)$")
if not KIND then return end
local YT = KIND == "youtube"

-- What the player's asked to do: the CD player's queue commands
-- (player-state.lua), or plain mpv ones for YouTube (positions count from 1)
local function cmd_play(i) return YT and { "playlist-play-index", tostring(i - 1) } or { "script-message", "music-play", tostring(i) } end
local function cmd_remove(i) return YT and { "playlist-remove", tostring(i - 1) } or { "script-message", "music-remove", tostring(i) } end
local function cmd_move(from, to)
    if YT then return { "playlist-move", tostring(from - 1), tostring(from < to and to or to - 1) } end
    return { "script-message", "music-move", tostring(from), tostring(to) }
end
local function cmd_clear() return YT and { "playlist-clear" } or { "script-message", "music-clear" } end

local STATE      = "/tmp/mpv-" .. KIND .. ".state.json"
local SOCK       = "/tmp/mpv-" .. KIND
local ALIVE      = "/tmp/mpv-" .. KIND .. ".list.alive"
local PREFS_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. KIND .. "-prefs" })

local DISPLAYS = {
    blue  = { "#9FE8FF", "#4E8FA6", "#0B171B" },
    red   = { "#FF5A47", "#9A3326", "#1C0C0A" },
    green = { "#7DFFB0", "#3E9A66", "#0A1912" },
    amber = { "#FFB347", "#A06A22", "#1C1409" },
}
local C = {
    plate = "#0E0E10", plate_top = "#1C1C20", plate_lo = "#030304", streak = "#FFFFFF",
    silk = "#C9C9CE", silk_dim = "#707078", bezel = "#1A1A1D", window = "#040506",
    button = "#18181B", button_rim = "#3A3A40", text = "#BEB9B1",
}
local FONT = "Helvetica Neue"

---------------------------------------------------------------------------
-- Drawing (ASS), on a grid 760 wide, as tall as the window's shape makes it
-- (the TV guide's look: big text in one display, touch-style buttons)
---------------------------------------------------------------------------

local GW, GH = 760, 600
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

local function shape(path, color, a, blur)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s\\p1}%s{\\p0}",
        col(color), a or 0, f1(N(blur or 0)), path)
end

-- Text; clip = {x, y, w, h} keeps long titles inside their column
local function text(x, y, align, size, color, s, o)
    o = o or {}
    s = (s or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", " ")
    local c = o.clip and string.format("\\clip(%s,%s,%s,%s)", f1(X(o.clip[1])), f1(Y(o.clip[2])),
        f1(X(o.clip[1] + o.clip[3])), f1(Y(o.clip[2] + o.clip[4]))) or ""
    return string.format("{\\q2\\an%d\\pos(%s,%s)%s\\fn%s\\fs%s\\fsp%s\\b%d\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s}%s",
        align, f1(X(x)), f1(Y(y)), c, FONT, f1(N(size)), f1(N(o.spacing or 0)), o.bold and 1 or 0,
        col(color), o.alpha or 0, f1(N(o.blur or 0)), s)
end

---------------------------------------------------------------------------
-- Layout (grid units): a table in one display window
---------------------------------------------------------------------------

local ROW = 44                                         -- row pitch
local G, RULER, ROW0, ROWS, COL, CLEAR_BTN

local function layout()
    G = { x = 16, y = 42, w = GW - 32, h = GH - 42 - 16 }   -- the display window
    RULER = G.y + 50                                   -- column headings
    ROW0 = G.y + 62                                    -- first row
    ROWS = math.max(3, math.floor((G.y + G.h - 10 - ROW0) / ROW))
    local x0, x1 = G.x + 10, G.x + G.w - 10
    COL = { num = x0 + 36, title = x0 + 54, time = x1 - 40, x = x1 - 14 }
    COL.album = COL.title + math.floor((COL.time - 64 - COL.title) * 0.6)
    CLEAR_BTN = { x = G.x + G.w - 14 - 64 - 112, y = G.y + 8, w = 112, h = 30 }
end
layout()

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local overlay = mp.create_osd_overlay("ass-events")
local state, last_raw, started = {}, nil, os.time()
local theme = "amber"
local top = 0                                          -- first row shown (0-based)
local drag = nil                                       -- { from = n } while dragging a track
local clear_down, last_minute = nil, nil                                 -- CLEAR showing pressed until then
local last_pos = nil
local lengths, probing = {}, 0                         -- track lengths (ffprobe), by path
local channels = {}                                    -- YouTube: uploader, by link

local function send(...)                               -- commands to the player, in order
    local lines = {}
    for _, c in ipairs({ ... }) do lines[#lines + 1] = utils.format_json({ command = c }) end
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "/bin/sh", "-c", 'printf "%s\\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1', "sh",
                 table.concat(lines, "\n"), SOCK },
    }, function() end)
end

local function read_theme()
    local f = io.open(PREFS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local c = line:match("^colour=(%a+)$")
        if c and DISPLAYS[c] then theme = c end
    end
    f:close()
end

local function count() return #(state.titles or {}) end
local function current() return (state["playlist-pos"] or -1) + 1 end

local function album_of(path)                          -- the folder a track's in
    local dir = (path or ""):match("(.*)/[^/]*$") or ""
    local name = dir:match("([^/]+)$") or ""
    if name:lower():match("^cd%s*%d+$") or name:lower():match("^disc%s*%d+$") then   -- Album/CD1
        name = (dir:match("([^/]+)/[^/]+$") or "") .. "  ·  " .. name
    end
    return name
end

local function hms(sec)
    sec = math.floor(sec + 0.5)
    local h, m, s2 = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    return h > 0 and string.format("%d:%02d:%02d", h, m, s2) or string.format("%d:%02d", m, s2)
end

local render
-- Lengths of the tracks showing, a few at a time (YouTube: the channel and
-- length, from yt-dlp, one at a time)
local function probe(paths)
    for _, p in ipairs(paths) do
        if probing >= (YT and 1 or 3) then return end
        if YT and p and lengths[p] == nil and p:match("^https?://") then
            lengths[p] = false
            probing = probing + 1
            mp.command_native_async({
                name = "subprocess", capture_stdout = true, playback_only = false,
                args = { "yt-dlp", "--no-warnings", "--skip-download", "--no-playlist",
                         "--print", "%(channel,uploader)s\t%(duration_string)s", p },
            }, function(ok, res)
                probing = probing - 1
                local ch, d = ((ok and res and res.stdout) or ""):match("([^\t\n]*)\t([^\n]*)")
                channels[p] = (ch and ch ~= "NA") and ch or ""
                lengths[p] = (d and d ~= "NA") and d or ""
                render()
            end)
        end
        if not YT and p and lengths[p] == nil and not p:match("^%a+://") then
            lengths[p] = false
            probing = probing + 1
            mp.command_native_async({
                name = "subprocess", capture_stdout = true, playback_only = false,
                args = { "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p },
            }, function(ok, res)
                probing = probing - 1
                local d = ok and res and tonumber((res.stdout or ""):match("[%d%.]+"))
                lengths[p] = d and hms(d) or ""
                render()
            end)
        end
    end
end

local function grid_mouse()
    local m = mp.get_property_native("mouse-pos") or {}
    return ((m.x or -1) - OX) / S, ((m.y or -1) - OY) / S
end

local function inside(x, y, r) return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end

-- The track under the mouse (its number), and whether it's on the ×
local function row_hit(x, y)
    if x < G.x or x > G.x + G.w or y < ROW0 or y >= ROW0 + ROWS * ROW then return nil end
    local n = top + 1 + math.floor((y - ROW0) / ROW)
    if n > count() then return nil end
    return n, x >= COL.x - 18
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

local static = { w = 0, h = 0, theme = nil, data = "" }

local function build_static(w, h)
    local ev = {}
    ev[#ev + 1] = shape(rect_path(0, 0, GW, GH), C.plate_lo)
    ev[#ev + 1] = shape(rrect_path(6, 6, GW - 12, GH - 12, 12), C.plate_top)
    ev[#ev + 1] = shape(rrect_path(6, 9, GW - 12, GH - 15, 12), C.plate)
    local brush = {}
    for i = 0, math.floor((GH - 30) / 4) do
        brush[#brush + 1] = rect_path(16, 16 + i * 4 + (i * 7 % 3), GW - 32, 0.7)
    end
    ev[#ev + 1] = shape(table.concat(brush), C.streak, 247)

    ev[#ev + 1] = text(G.x + 4, 22, 4, 17, C.silk, "mpv-tvh", { bold = true, spacing = 1.2 })
    ev[#ev + 1] = text(G.x + 90, 23, 4, 10, C.silk, "PL-252", { bold = true, spacing = 1.5 })
    ev[#ev + 1] = text(G.x + 142, 23, 4, 7.5, C.silk_dim, "PLAYLIST", { spacing = 2.5 })
    ev[#ev + 1] = text(G.x + G.w, 23, 6, 7.5, C.silk_dim,
        (YT and "DROP OR PASTE LINKS" or "DROP MUSIC HERE")
        .. "  ·  DOUBLE-CLICK PLAYS  ·  DRAG TO MOVE  ·  ×  REMOVES", { spacing = 1.5 })

    ev[#ev + 1] = shape(rrect_path(G.x - 7, G.y - 7, G.w + 14, G.h + 14, 9), C.bezel)
    ev[#ev + 1] = shape(rrect_path(G.x - 7, G.y - 7, G.w + 14, 3, 2), "#000000", 60)
    ev[#ev + 1] = shape(rrect_path(G.x, G.y, G.w, G.h, 4), C.window)

    static.w, static.h, static.theme, static.data = w, h, theme, table.concat(ev, "\n")
end

render = function()
    local w, h = mp.get_osd_size()
    if not w or w == 0 or h == 0 then return end
    if w ~= static.w or h ~= static.h or theme ~= static.theme then
        overlay.res_x, overlay.res_y = w, h
        GH = math.max(300, math.min(2400, GW * h / w))   -- the window's shape
        layout()
        S = math.min(w / GW, h / GH)
        OX, OY = (w - GW * S) / 2, (h - GH * S) / 2
        build_static(w, h)
    end
    local FL = DISPLAYS[theme]
    local ev = { static.data }
    local n, cur = count(), current()
    local titles, paths = state.titles or {}, state.paths or {}

    -- Heading: what's playing of how many, CLEAR, and the time
    ev[#ev + 1] = text(G.x + 14, G.y + 22, 4, 19, FL[1], "PLAYLIST", { bold = true, spacing = 3 })
    if n > 0 then
        ev[#ev + 1] = text(G.x + 160, G.y + 23, 4, 10.5, FL[2],
            cur > 0 and string.format((YT and "VIDEO" or "TRACK") .. " %d OF %d", cur, n)
                or (YT and (n == 1 and "1 VIDEO" or (n .. " VIDEOS")) or (n == 1 and "1 TRACK" or (n .. " TRACKS"))),
            { spacing = 2 })
    end
    ev[#ev + 1] = text(G.x + G.w - 14, G.y + 22, 6, 19, FL[1], os.date("%H:%M"), { bold = true, spacing = 2 })
    local b = CLEAR_BTN
    local on = n > 1 or (n == 1 and cur == 0)
    local down = clear_down and mp.get_time() < clear_down
    ev[#ev + 1] = shape(rrect_path(b.x, b.y, b.w, b.h, 5), on and FL[2] or FL[3])
    ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 1.5, b.w - 3, b.h - 3, 4), down and FL[3] or C.window)
    ev[#ev + 1] = text(b.x + b.w / 2, b.y + 11.5, 5, 12.5, on and FL[1] or FL[3], "CLEAR", { bold = true, spacing = 1 })
    ev[#ev + 1] = text(b.x + b.w / 2, b.y + 23, 5, 7, on and FL[2] or FL[3], "ALL BUT WHAT'S PLAYING",
        { spacing = 0.3 })

    -- Column headings
    ev[#ev + 1] = text(COL.num, RULER, 3, 11, FL[2], "#", { spacing = 2 })
    ev[#ev + 1] = text(COL.title, RULER, 1, 11, FL[2], "TITLE", { spacing = 2 })
    ev[#ev + 1] = text(COL.album, RULER, 1, 11, FL[2], YT and "CHANNEL" or "ALBUM", { spacing = 2 })
    ev[#ev + 1] = text(COL.time, RULER, 3, 11, FL[2], "TIME", { spacing = 2 })
    ev[#ev + 1] = shape(rect_path(G.x + 14, RULER + 6, G.w - 28, 1), FL[3])

    if n == 0 then
        ev[#ev + 1] = text(G.x + G.w / 2, ROW0 + (ROWS * ROW) / 2, 5, 15, FL[2],
            YT and "DROP YOUTUBE LINKS HERE, OR PASTE ONE ON THE FACEPLATE" or "DROP MUSIC FILES OR FOLDERS HERE",
            { spacing = 3 })
    end

    top = math.max(0, math.min(top, n - ROWS))
    local want = {}
    for r = 1, ROWS do
        local i = top + r
        if i > n then break end
        local y = ROW0 + (r - 1) * ROW
        local cy = y + ROW / 2
        local now, done = i == cur, cur > 0 and i < cur
        if now then                                    -- the guide's selection: an outlined box
            ev[#ev + 1] = shape(rrect_path(G.x + 8, y + 4, G.w - 16, ROW - 8, 4), FL[1])
            ev[#ev + 1] = shape(rrect_path(G.x + 10.5, y + 6.5, G.w - 21, ROW - 13, 3), C.window)
            ev[#ev + 1] = shape(rrect_path(G.x + 10.5, y + 6.5, G.w - 21, ROW - 13, 3), FL[3], 40)
        end
        local c = now and FL[1] or FL[2]
        local a = done and 110 or 0
        ev[#ev + 1] = text(COL.num, cy, 6, 13, c, tostring(i), { alpha = a, spacing = 1 })
        if now then ev[#ev + 1] = text(COL.title - 5, cy, 6, 10, FL[1], "▶") end
        ev[#ev + 1] = text(COL.title, cy, 4, 17, now and FL[1] or (done and FL[2] or FL[1]), titles[i] or "",
            { bold = now, alpha = done and 110 or (now and 0 or 40), clip = { COL.title, y, COL.album - 14 - COL.title, ROW } })
        ev[#ev + 1] = text(COL.album, cy, 4, 14, c, YT and (channels[paths[i] or ""] or "") or album_of(paths[i]),
            { alpha = a, clip = { COL.album, y, COL.time - 64 - COL.album, ROW } })
        local len = paths[i] and lengths[paths[i]]
        if len then ev[#ev + 1] = text(COL.time, cy, 6, 13, c, len, { alpha = a, spacing = 1 }) end
        if not now then ev[#ev + 1] = text(COL.x, cy, 5, 17, FL[2], "×", { alpha = a }) end
        want[#want + 1] = paths[i]
    end
    probe(want)
    if n > ROWS then                                   -- where in the queue
        local th = math.max(16, ROWS * ROW * ROWS / n)
        local ty = ROW0 + (ROWS * ROW - th) * top / (n - ROWS)
        ev[#ev + 1] = shape(rrect_path(G.x + G.w - 6, ty, 3.5, th, 2), FL[2])
    end

    -- Where a dragged track will land
    if drag then
        local mx, my = grid_mouse()
        local t = row_hit(math.max(G.x + 1, math.min(mx, COL.x - 30)), my)
        if t then
            local y = ROW0 + (t - top - 1 + (t > drag.from and 1 or 0)) * ROW
            ev[#ev + 1] = shape(rect_path(G.x + 12, y - 1.5, G.w - 24, 3), FL[1], 0, 1.5)
        end
    end

    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

---------------------------------------------------------------------------
-- Mouse
---------------------------------------------------------------------------

mp.add_forced_key_binding("MBTN_LEFT", "list-click", function(e)
    local x, y = grid_mouse()
    if e.event == "down" then
        local i, on_x = row_hit(x, y)
        if i and on_x and i ~= current() then
            send(cmd_remove(i))
        elseif i then
            drag = { from = i }
        elseif inside(x, y, CLEAR_BTN) then
            clear_down = mp.get_time() + 0.15
            mp.add_timeout(0.16, render)
            send(cmd_clear())
            render()
        elseif not inside(x, y, G) then
            pcall(mp.commandv, "begin-vo-dragging")    -- drag the window by its front panel
        end
    elseif e.event == "up" and drag then
        local to = row_hit(math.max(G.x + 1, math.min(x, COL.x - 30)), y)
        if to and to ~= drag.from then
            send(cmd_move(drag.from, to))
        end
        drag = nil
        render()
    end
end, { complex = true })

-- Double-click plays a track. (mpv's own double-click, full screen, would
-- win over a script's key binding, so replace it with keybind.)
mp.commandv("keybind", "MBTN_LEFT_DBL", "script-message playlist-double-click")
mp.register_script_message("playlist-double-click", function()
    local i, on_x = row_hit(grid_mouse())
    if i and not on_x then send(cmd_play(i)) end
end)

local function wheel(d)
    return function()
        top = top + d
        render()
    end
end
mp.add_forced_key_binding("WHEEL_UP", "list-up", wheel(-1))
mp.add_forced_key_binding("WHEEL_DOWN", "list-down", wheel(1))
mp.observe_property("mouse-pos", "native", function() if drag then render() end end)

---------------------------------------------------------------------------
-- Dropped files and folders: mpv adds them to this window's own (empty)
-- playlist; pass them on to the player, in order, and clear it again.
---------------------------------------------------------------------------

mp.observe_property("playlist", "native", function(_, list)
    if not list or #list == 0 then return end
    local cmds = {}
    for _, e in ipairs(list) do
        local path = e.filename
        if not path:match("^%a+://") then
            path = utils.join_path(mp.get_property("working-directory", ""), path)
        end
        cmds[#cmds + 1] = YT and { "script-message", "yt-queue", path, "" } or { "script-message", "music-add", path }
    end
    send((table.unpack or unpack)(cmds))
    mp.commandv("stop")
end)

---------------------------------------------------------------------------
-- Follow the player; heartbeat for the faceplate
---------------------------------------------------------------------------

mp.add_periodic_timer(0.25, function()
    local f = io.open(STATE, "r")
    local raw = f and f:read("*a")
    if f then f:close() end
    if raw and raw ~= last_raw then
        local s = utils.parse_json(raw)
        if s and (s.t or 0) >= started - 30 then
            last_raw, state = raw, s
            if s.closed then mp.command("quit"); return end
            local cur = current()
            if cur ~= last_pos then last_pos, top = cur, math.max(0, cur - 3) end   -- new track: follow it
            render()
        end
    end
    if state.t and os.time() - state.t > 6 then mp.command("quit") end   -- player gone
end)

mp.add_periodic_timer(1, function()
    local f = io.open(ALIVE, "w")
    if f then f:write(os.time(), "\n"); f:close() end
    local before, minute = theme, os.date("%H:%M")
    read_theme()
    if theme ~= before or minute ~= last_minute then last_minute = minute; render() end
end)

read_theme()
mp.observe_property("osd-dimensions", "native", function() render() end)
mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
