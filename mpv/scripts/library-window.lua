-- library-window.lua
-- The CD player's music library (LB-252, control socket /tmp/mpv-lib-music)
-- and the video player's video library (/tmp/mpv-lib-video): its own
-- media-less mpv window, opened and closed by the preamp's LIBRARY button
-- (through the faceplate), which Hammerspoon puts under the stack (the
-- faceplates' width, down to the bottom of the screen), and drawn on the
-- same brushed-black front as the faceplates. It fills whatever shape it's
-- given: more rows when it's taller.
--
--   Columns, like Finder's column view: each one lists a folder of the music
--   library (script-opt lib-root, ~/Music by default), so a genre / artist /
--   album / track library reads left to right. Only folders with music in
--   them are shown. Click to select; clicking a folder of tracks (an album)
--   plays it too, and double-clicking a track plays it. PLAY NOW plays the
--   selection next, PLAY NEXT queues it after the track playing, ADD puts
--   it at the end of the queue and ADD ALL adds everything in the column.
--   Track lengths and formats come from ffprobe when it's installed.
--
--   Keys: arrows (knob 1, through Hammerspoon: Left / Right, the columns;
--   knob 2: Up / Down; pressing either plays a track or album or opens a
--   folder, Alt + press adds), typing
--   jumps to a name, / or a click on the search box searches the whole
--   library, Esc clears the search.
--   Pad keys 1-8 play queue tracks 1-8, as on the faceplate. The preamp's
--   MONITOR LIBRARY button opens and closes it.
--
-- It sends commands to the player over /tmp/mpv-music with nc, writes
-- /tmp/mpv-music.lib.alive while open, follows the faceplate's display
-- colour, remembers the selection, and closes when the player quits.

local mp = require 'mp'
local utils = require 'mp.utils'

local KIND = (mp.get_property("input-ipc-server") or ""):match("/mpv%-lib%-(%a+)$")
if not KIND or KIND == "tv" or KIND == "radio" then return end   -- theirs is the guide (guide-window.lua)

local STATE      = "/tmp/mpv-" .. KIND .. ".state.json"
local SOCK       = "/tmp/mpv-" .. KIND
local ALIVE      = "/tmp/mpv-" .. KIND .. ".lib.alive"
local PREFS_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. KIND .. "-prefs" })
local SEL_FILE   = mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. KIND .. "-library" })
local ROOT = (mp.get_opt("lib-root") or ""):gsub("/+$", "")
if ROOT == "" then ROOT = mp.command_native({ "expand-path", "~/Music" }) end
local HOME = os.getenv("HOME") or ""
local ROOT_LABEL = (HOME ~= "" and ROOT:sub(1, #HOME) == HOME) and ("~" .. ROOT:sub(#HOME + 1)) or ROOT

local AUDIO = {}
for e in ("mp3 flac m4a aac alac ogg oga opus wav wave aif aiff aifc wma ape wv mpc dsf dff mka tta ac3"):gmatch("%S+") do
    AUDIO[e] = true
end
if KIND == "video" then                  -- the video player's: videos, and audio recordings
    for e in ("mkv mp4 m4v mov avi webm ts m2ts mts wmv flv mpg mpeg ogv 3gp"):gmatch("%S+") do
        AUDIO[e] = true
    end
end

local DISPLAYS = {
    blue  = { "#9FE8FF", "#4E8FA6", "#0B171B" },
    red   = { "#FF5A47", "#9A3326", "#1C0C0A" },
    green = { "#7DFFB0", "#3E9A66", "#0A1912" },
    amber = { "#FFB347", "#A06A22", "#1C1409" },
}
local C = {
    plate = "#0E0E10", plate_top = "#1C1C20", plate_lo = "#030304", streak = "#FFFFFF",
    silk = "#C9C9CE", silk_dim = "#707078", bezel = "#1A1A1D", window = "#040506",
    button = "#18181B", button_rim = "#3A3A40", button_dn = "#0B0B0D",
    text = "#BEB9B1", rule = "#202024", led_off = "#1B1D1C",
}
local FONT = "Helvetica Neue"

---------------------------------------------------------------------------
-- Drawing (ASS), on a grid 880 wide (the TV guide's), as tall as the
-- window's shape makes it
---------------------------------------------------------------------------

local GW, GH = 880, 600                 -- GH follows the window's shape
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

local function shape(path, color, a, blur)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s\\p1}%s{\\p0}",
        col(color), a or 0, f1(N(blur or 0)), path)
end

-- Text; clip = {x, y, w, h} keeps long names inside their column
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
-- Layout (grid units)
---------------------------------------------------------------------------

local SLOTS = { 0.22, 0.25, 0.23, 0.30 }               -- column widths, left to right
-- Buttons in the details panel, as on the guide (a touch screen)
local BW, BH, BG = 122, 34, 7
local BUTTONS = {
    { label = "PLAY NOW",  sub = "ENTER · CLICK AN ALBUM" },
    { label = "PLAY NEXT", sub = "AFTER THIS ONE" },
    { label = "ADD",       sub = "ALT + ENTER" },
    { label = "ADD ALL",   sub = "THE WHOLE COLUMN" },
    { label = "RESCAN",    sub = "LOOK FOR NEW MUSIC" },
    { label = "CLOSE",     sub = "ALT + 5" },
}
local ROW = 40                                        -- row pitch
local DET_MIN = 3 * BH + 2 * BG + 14                  -- the details, at least
local D, RULER, ROW0, ROWS, AZ, SEARCH, DET

-- The display fills the window; the columns get the rows that fit above
-- the details of the selection
local function layout()
    D = { x = 16, y = 42, w = GW - 32, h = GH - 42 - 16 }
    RULER = D.y + 50                                  -- column headings
    ROW0 = D.y + 62
    ROWS = math.max(3, math.floor((D.y + D.h - 10 - DET_MIN - 10 - ROW0) / ROW))
    DET = { x = D.x + 10, y = ROW0 + ROWS * ROW + 10 }
    DET.w, DET.h = D.w - 20, D.y + D.h - 10 - DET.y
    SEARCH = { x = D.x + 168, y = D.y + 9, w = 220, h = 27 }
    AZ = { x = D.x + 412, y = D.y + 23, pitch = 11.6 }
    for k, b in ipairs(BUTTONS) do
        b.x = DET.x + DET.w - 8 - 2 * BW - 8 + ((k - 1) % 2) * (BW + 8)
        b.y = DET.y + 6 + math.floor((k - 1) / 2) * (BH + BG)
    end
end
layout()

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local backdrop = mp.create_osd_overlay("ass-events")  -- the front panel: drawn once per size
backdrop.z = -1
local overlay = mp.create_osd_overlay("ass-events")   -- what changes
local theme = "amber"
local tree, flat = nil, {}             -- the library, and every entry in order (for search)
local scanning, scan_error = false, nil
local levels, focus = {}, 1            -- open columns: { node =, sel =, top = }
local query, search_focus = "", false
local results, res_sel, res_top = {}, 1, 0
local meta, probing = {}, {}           -- ffprobe results by path
local playing_path = nil               -- the track playing in the player
local notice = { text = nil, until_t = 0 }
local pressed = { id = nil, until_t = 0 }
local jump = { buf = "", t = 0 }
local started, last_raw, last_t = os.time(), nil, nil

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

local render
local osd_w, osd_h = 0, 0

-- Bursts of events (a trackpad's scrolling) redraw once per frame at most
local redraw_timer
local function redraw_soon()
    if redraw_timer then return end
    redraw_timer = mp.add_timeout(1 / 60, function() redraw_timer = nil; render() end)
end

---------------------------------------------------------------------------
-- The library: one `find` over the music folder, built into a tree of the
-- folders that have music in them
---------------------------------------------------------------------------

local function natural_key(s)
    return (s:lower():gsub("%d+", function(d) return string.format("%012d", tonumber(d)) end))
end

-- A track's number and title from its file name: "1-09 Whispers.m4a"
local function parse_name(name)
    local base = name:gsub("%.[^.]+$", "")
    local num, title = base:match("^(%d%d?%-%d%d?%d?)[%s%._%-]+(.+)$")
    if not num then num, title = base:match("^(%d%d?%d?)%s*[%.%-_]?%s+(.+)$") end
    return num or "", title or base
end

local function new_dir(name, path, parent)
    return { dir = true, name = name, label = name:gsub("%.localized$", ""), path = path, parent = parent,
             dirs = {}, files = {}, entries = {}, count = 0 }
end

local function build(out)
    local root = new_dir(ROOT:match("([^/]+)$") or ROOT, ROOT, nil)
    local prefix = ROOT .. "/"
    for line in out:gmatch("[^\n]+") do
        if line:sub(1, #prefix) == prefix and AUDIO[(line:match("%.([^./]+)$") or ""):lower()] then
            local parts = {}
            for p in line:sub(#prefix + 1):gmatch("[^/]+") do parts[#parts + 1] = p end
            local node = root
            for i = 1, #parts - 1 do
                local d = node.dirs[parts[i]]
                if not d then
                    d = new_dir(parts[i], node.path .. "/" .. parts[i], node)
                    node.dirs[parts[i]] = d
                end
                node = d
            end
            local num, title = parse_name(parts[#parts])
            node.files[#node.files + 1] = { name = parts[#parts], label = title, num = num, path = line,
                                            parent = node }
        end
    end
    flat = {}
    local function finish(d)
        local entries = {}
        for _, c in pairs(d.dirs) do entries[#entries + 1] = c end
        for _, f in ipairs(d.files) do entries[#entries + 1] = f end
        for _, e in ipairs(entries) do e.key = natural_key(e.name) end
        table.sort(entries, function(a, b) return a.key < b.key end)
        d.entries, d.leaf, d.count = entries, next(d.dirs) == nil, #d.files
        for _, e in ipairs(entries) do
            flat[#flat + 1] = e
            e.find = e.path:sub(#prefix + 1):lower()
            e.lname = e.label:lower()
            if e.dir then d.count = d.count + finish(e) end
        end
        return d.count
    end
    finish(root)
    return root
end

---------------------------------------------------------------------------
-- Track lengths and formats, from ffprobe, a folder at a time
---------------------------------------------------------------------------

local function probe(files)
    local paths = {}
    for _, f in ipairs(files) do
        if not f.dir and not meta[f.path] and not probing[f.path] and #paths < 200 then
            paths[#paths + 1] = f.path
            probing[f.path] = true
        end
    end
    if #paths == 0 then return end
    -- Four at a time, one line per file: path TAB key=value|key=value...
    local args = { "/bin/sh", "-c",
        'command -v ffprobe >/dev/null 2>&1 || exit 0; printf "%s\\0" "$@" | xargs -0 -n 1 -P 4 sh -c ' ..
        '\'printf "@@%s\\t%s\\n" "$1" "$(ffprobe -v quiet -select_streams a:0 -show_entries ' ..
        'stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample:format=duration ' ..
        '-of default=nw=1 "$1" | tr "\\n" "|")"\' sh', "sh" }
    for _, p in ipairs(paths) do args[#args + 1] = p end
    mp.command_native_async({ name = "subprocess", args = args, capture_stdout = true, playback_only = false },
        function(_, r)
            for line in ((r and r.stdout) or ""):gmatch("[^\n]+") do
                local path, fields = line:match("^@@(.-)\t(.*)$")
                if path then
                    local m = {}
                    for k, v in fields:gmatch("([%w_]+)=([^|]*)") do
                        if v ~= "N/A" then m[k] = v end
                    end
                    meta[path] = m
                end
            end
            for _, p in ipairs(paths) do probing[p] = nil; meta[p] = meta[p] or {} end
            redraw_soon()
        end)
end

local function hms(sec)
    sec = math.floor(sec + 0.5)
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    return h > 0 and string.format("%d:%02d:%02d", h, m, s) or string.format("%d:%02d", m, s)
end

local function duration(e)
    local d = meta[e.path] and tonumber(meta[e.path].duration or "")
    return d and hms(d) or ""
end

local LOSSLESS = { flac = true, alac = true, wavpack = true, ape = true, tta = true }

-- "FLAC 24 / 96" and whether it's better than CD
local function format_of(e)
    local m = meta[e.path]
    if not m or not m.codec_name then return nil, false end
    local codec = m.codec_name
    local lossless = LOSSLESS[codec] or codec:match("^pcm") ~= nil
    local name = codec:match("^pcm") and ((e.name:match("%.(%w+)$") or "pcm"):upper()) or codec:upper()
    local rate = tonumber(m.sample_rate or "") or 0
    local bits = tonumber(m.bits_per_raw_sample or "") or 0
    if bits == 0 then bits = tonumber(m.bits_per_sample or "") or 0 end
    local khz = rate > 0 and ((rate % 1000 == 0) and tostring(math.floor(rate / 1000)) or string.format("%.1f", rate / 1000)) or ""
    local s = name
    if lossless and bits > 0 then s = s .. "  " .. bits .. " / " .. khz elseif khz ~= "" then s = s .. "  " .. khz end
    return s, rate > 48000 or (lossless and bits >= 24)
end

---------------------------------------------------------------------------
-- Columns and selection
---------------------------------------------------------------------------

local function entry_of(l) return l and l.sel and l.node.entries[l.sel] end

local function keep_visible(l, sel, count)
    if not sel then return end
    if sel <= l.top then l.top = sel - 1 end
    if sel > l.top + ROWS then l.top = sel - ROWS end
    l.top = math.max(0, math.min(l.top, math.max(0, count - ROWS)))
end

local function visible_range()
    local first = math.max(1, #levels - 3)
    if focus < first then first = focus end
    return first, math.min(#levels, first + 3)
end

local probe_timer
local function probe_now()
    if query ~= "" then
        local list = {}
        for k = res_top + 1, math.min(#results, res_top + ROWS) do list[#list + 1] = results[k] end
        probe(list)
        return
    end
    local first, last = visible_range()
    for i = first, last do probe(levels[i].node.files) end
end

-- Track details are fetched once the selection settles, not for every
-- folder passed on the way
local function probe_visible()
    if probe_timer then probe_timer:kill() end
    probe_timer = mp.add_timeout(0.25, probe_now)
end

local save_timer
local function save_selection()
    local e = entry_of(levels[focus]) or entry_of(levels[focus - 1])
    if not e then return end
    local f = io.open(SEL_FILE, "w")
    if f then f:write(e.path, "\n"); f:close() end
end

-- Select entry idx in column i; a folder opens in the next column
local function choose(i, idx, quiet)
    local l = levels[i]
    if not l or #l.node.entries == 0 then return end
    idx = math.max(1, math.min(idx, #l.node.entries))
    if l.sel ~= idx or #levels ~= i + ((l.node.entries[idx].dir) and 1 or 0) then
        l.sel = idx
        for k = #levels, i + 1, -1 do levels[k] = nil end
        local e = l.node.entries[idx]
        if e.dir then levels[i + 1] = { node = e, sel = nil, top = 0 } end
    end
    focus = i
    keep_visible(l, l.sel, #l.node.entries)
    if quiet then return end
    probe_visible()
    if save_timer then save_timer:kill() end
    save_timer = mp.add_timeout(1, save_selection)
    render()
end

-- Open the columns down to a path (a track or folder in the library)
local function reveal(path)
    levels, focus = { { node = tree, sel = nil, top = 0 } }, 1
    if not path or path:sub(1, #ROOT + 1) ~= ROOT .. "/" then return end
    local node, i = tree, 1
    for part in path:sub(#ROOT + 2):gmatch("[^/]+") do
        local idx
        for k, e in ipairs(node.entries) do if e.name == part then idx = k; break end end
        if not idx then break end
        choose(i, idx, true)
        node = node.entries[idx]
        if not node.dir then break end
        i = i + 1
    end
    probe_visible()
end

local function current()
    if query ~= "" then return results[res_sel] end
    return entry_of(levels[focus])
end

local function do_search()
    results, res_sel, res_top = {}, 1, 0
    local words = {}
    for w in query:lower():gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return end
    for _, e in ipairs(flat) do
        -- every word somewhere in its path, and at least one in its own name
        local ok, own = true, false
        for _, w in ipairs(words) do
            if not e.find:find(w, 1, true) then ok = false; break end
            own = own or e.lname:find(w, 1, true) ~= nil
        end
        ok = ok and own
        if ok then
            results[#results + 1] = e
            if #results >= 500 then break end
        end
    end
    probe_visible()
end

local function set_query(q)
    query = q
    do_search()
    render()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function say(s)
    notice.text, notice.until_t = s, mp.get_time() + 2.5
    render()
    mp.add_timeout(2.6, function() render() end)
end

local function tracks(e) return e.dir and e.count or 1 end
local function plural(n) return n == 1 and "1 TRACK" or (n .. " TRACKS") end

local function add(e, mode)
    if not e then return end
    send({ "script-message", "music-add", e.path, mode })
    local what = (e.dir and e.label or e.label):upper()
    say((mode == "play" and "PLAYING  " or mode == "next" and "NEXT  " or "ADDED  ") .. what
        .. "  ·  " .. plural(tracks(e)))
end

local function add_all()
    if query ~= "" then
        local cmds, n = {}, 0
        for _, e in ipairs(results) do
            if not e.dir then
                cmds[#cmds + 1] = { "script-message", "music-add", e.path, "end" }
                n = n + 1
            end
        end
        if n > 0 then send((table.unpack or unpack)(cmds)); say("ADDED  " .. plural(n)) end
        return
    end
    local l = levels[focus]
    if not l or l.node == tree then return end      -- not the whole library by accident
    add(l.node, "end")
end

local function rescan() end                          -- defined below

local ACTIONS = {
    ["PLAY NOW"]  = function() add(current(), "play") end,
    ["PLAY NEXT"] = function() add(current(), "next") end,
    ["ADD"]       = function() add(current(), "end") end,
    ["ADD ALL"]   = add_all,
    ["RESCAN"]    = function() rescan() end,
    ["CLOSE"]     = function() mp.command("quit") end,
}

local function move(d)
    if not tree then return end
    if query ~= "" then
        if #results == 0 then return end
        res_sel = math.max(1, math.min(#results, res_sel + d))
        if res_sel <= res_top then res_top = res_sel - 1 end
        if res_sel > res_top + ROWS then res_top = res_sel - ROWS end
        probe_visible()
        render()
        return
    end
    local l = levels[focus]
    choose(focus, (l.sel or 0) + d)
end

local function go_right()
    if not tree then return end
    if query ~= "" then                              -- show a result in the columns
        local e = results[res_sel]
        if e then
            search_focus = false
            set_query("")
            reveal(e.path)
            render()
        end
        return
    end
    local e = entry_of(levels[focus])
    if e and e.dir and #e.entries > 0 then choose(focus + 1, levels[focus + 1].sel or 1) end
end

local function go_left()
    if query ~= "" or focus <= 1 then return end
    focus = focus - 1
    render()
end

-- Knob press / Enter: a track or an album (a folder of tracks) plays, any
-- other folder opens
local function open_or_play()
    local e = current()
    if not e then
        if query == "" and levels[focus] and not levels[focus].sel then choose(focus, 1) end
        return
    end
    if e.dir and not e.leaf then go_right() else add(e, "play") end
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

local function icon_path(kind, cx, cy, s)
    local h = s / 2
    if kind == "play" then
        return poly_path({ cx - 0.45 * s, cy - h, cx + 0.55 * s, cy, cx - 0.45 * s, cy + h })
    elseif kind == "next" then                       -- play into the queue
        local t = 0.13 * s
        return poly_path({ cx - 0.95 * s, cy - h, cx - 0.15 * s, cy, cx - 0.95 * s, cy + h })
            .. rect_path(cx + 0.1 * s, cy - h, 0.85 * s, t) .. rect_path(cx + 0.1 * s, cy - t / 2, 0.85 * s, t)
            .. rect_path(cx + 0.1 * s, cy + h - t, 0.85 * s, t)
    elseif kind == "add" then
        local t = 0.14 * s
        return rect_path(cx - h, cy - t / 2, s, t) .. rect_path(cx - t / 2, cy - h, t, s)
    elseif kind == "addall" then                     -- a list and a plus
        local t = 0.13 * s
        return rect_path(cx - 0.95 * s, cy - h, 1.0 * s, t) .. rect_path(cx - 0.95 * s, cy - t / 2, 1.0 * s, t)
            .. rect_path(cx - 0.95 * s, cy + h - t, 0.6 * s, t)
            .. rect_path(cx + 0.25 * s, cy + 0.1 * s, 0.7 * s, t) .. rect_path(cx + 0.6 * s - t / 2, cy - 0.25 * s, t, 0.7 * s)
    end
    return ""
end

local static = { w = 0, h = 0, data = "" }

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

    ev[#ev + 1] = text(D.x + 4, 22, 4, 17, C.silk, "mpv-tvh", { bold = true, spacing = 1.2 })
    ev[#ev + 1] = text(D.x + 90, 23, 4, 10, C.silk, "LB-252", { bold = true, spacing = 1.5 })
    ev[#ev + 1] = text(D.x + 142, 23, 4, 7.5, C.silk_dim, KIND == "video" and "VIDEO LIBRARY" or "MUSIC LIBRARY",
        { spacing = 2.5 })
    ev[#ev + 1] = text(D.x + D.w, 23, 6, 7.5, C.silk_dim,
        "KNOB 1: COLUMNS  ·  KNOB 2: UP / DOWN  ·  PRESS PLAYS  ·  TYPE TO JUMP  ·  /  SEARCHES", { spacing = 1.5 })

    ev[#ev + 1] = shape(rrect_path(D.x - 7, D.y - 7, D.w + 14, D.h + 14, 9), C.bezel)
    ev[#ev + 1] = shape(rrect_path(D.x - 7, D.y - 7, D.w + 14, 3, 2), "#000000", 60)
    ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), C.window)
    static.w, static.h, static.data = w, h, table.concat(ev, "\n")
end

local hits = {}                                       -- clickable rows: { x, y, w, h, ... }

local function playing_in(e)
    if not playing_path then return false end
    if not e.dir then return e.path == playing_path end
    return playing_path:sub(1, #e.path + 1) == e.path .. "/"
end

-- One row of a column or of the search results. The selection in the
-- column being browsed is the guide's outlined box; on the way to it, filled
local function draw_row(ev, FL, e, x, y, w, sel, active, loc)
    if sel and active then
        ev[#ev + 1] = shape(rrect_path(x + 3, y + 3, w - 6, ROW - 6, 4), FL[1])
        ev[#ev + 1] = shape(rrect_path(x + 5.5, y + 5.5, w - 11, ROW - 11, 3), C.window)
        ev[#ev + 1] = shape(rrect_path(x + 5.5, y + 5.5, w - 11, ROW - 11, 3), FL[3], 40)
    elseif sel then
        ev[#ev + 1] = shape(rrect_path(x + 3, y + 3, w - 6, ROW - 6, 4), FL[3])
    end
    local here = playing_in(e)
    local tc = (sel or here) and FL[1] or FL[2]
    local cy = y + ROW / 2
    local tail = 12
    if e.dir then
        ev[#ev + 1] = text(x + w - 12, cy, 6, 17, (sel or here) and FL[1] or FL[2], here and "▸" or "›")
        tail = 28
    else
        local d = duration(e)
        if d ~= "" then
            ev[#ev + 1] = text(x + w - 12, cy, 6, 13, sel and FL[1] or FL[2], d, { spacing = 1 })
            tail = 64
        end
    end
    local tx = x + 12
    if not e.dir and not loc then
        ev[#ev + 1] = text(x + 12, cy, 4, 13, sel and FL[1] or FL[2], e.num, { spacing = 1 })
        tx = x + (e.num:find("-") and 58 or 40)
    end
    if not e.dir and here then
        ev[#ev + 1] = text(tx - 4, cy, 6, 10, FL[1], "▶")
    end
    local tw = (loc and (w * 0.48) or (w - (tx - x) - tail))
    ev[#ev + 1] = text(tx, cy, 4, 16.5, tc, e.label, { bold = sel and active, clip = { tx, y, tw, ROW } })
    if loc then                                      -- search result: where it is
        local where = e.parent and e.parent.path:sub(#ROOT + 2) or ""
        ev[#ev + 1] = text(x + w * 0.52, cy, 4, 14, FL[2],
            where:gsub("/", "  ›  "), { clip = { x + w * 0.52, y, w * 0.48 - tail, ROW } })
    end
end

render = function()
    local w, h = osd_w, osd_h                       -- kept from osd-dimensions: asking is slow
    if not w or w == 0 or h == 0 then return end
    if w ~= static.w or h ~= static.h then
        overlay.res_x, overlay.res_y = w, h
        backdrop.res_x, backdrop.res_y = w, h
        GH = math.max(520, math.min(2200, GW * h / w))    -- the window's shape
        layout()
        S = math.min(w / GW, h / GH)
        OX, OY = (w - GW * S) / 2, (h - GH * S) / 2
        build_static(w, h)
        backdrop.data = static.data
        backdrop:update()
    end
    local FL = DISPLAYS[theme]
    local ev = {}
    hits = {}

    -- Heading: LIBRARY, the search box, A-Z, the time
    ev[#ev + 1] = text(D.x + 14, D.y + 22, 4, 19, FL[1], KIND == "video" and "VIDEOS" or "LIBRARY",
        { bold = true, spacing = 3 })
    ev[#ev + 1] = text(D.x + D.w - 14, D.y + 22, 6, 19, FL[1], os.date("%H:%M"), { bold = true, spacing = 2 })
    local sb = SEARCH
    ev[#ev + 1] = shape(rrect_path(sb.x, sb.y, sb.w, sb.h, 5), search_focus and FL[1] or FL[3])
    ev[#ev + 1] = shape(rrect_path(sb.x + 1.5, sb.y + 1.5, sb.w - 3, sb.h - 3, 4), C.window)
    if query == "" and not search_focus then
        ev[#ev + 1] = text(sb.x + 12, sb.y + sb.h / 2, 4, 12, FL[2], "SEARCH", { spacing = 2 })
    else
        ev[#ev + 1] = text(sb.x + 12, sb.y + sb.h / 2, 4, 14, FL[1], query .. (search_focus and "▏" or ""),
            { clip = { sb.x + 6, sb.y, sb.w - 12, sb.h } })
    end

    local cur = current()

    -- A-Z: the focused column's letters, current one lit
    local letter = cur and (cur.label:sub(1, 1):upper()) or ""
    if not letter:match("%a") and letter ~= "" then letter = "#" end
    local az = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#"
    for k = 1, #az do
        local ch = az:sub(k, k)
        ev[#ev + 1] = text(AZ.x + (k - 1) * AZ.pitch, AZ.y, 5, 11, ch == letter and FL[1] or FL[2], ch,
            { bold = ch == letter })
    end

    local bottom = ROW0 + ROWS * ROW
    if not tree then
        ev[#ev + 1] = text(D.x + D.w / 2, ROW0 + ROWS * ROW / 2, 5, 16, FL[2],
            scan_error or ("SCANNING  " .. ROOT_LABEL:upper() .. "  …"), { spacing = 3 })
    elseif #tree.entries == 0 then
        ev[#ev + 1] = text(D.x + D.w / 2, ROW0 + ROWS * ROW / 2, 5, 16, FL[2],
            "NOTHING FOUND IN  " .. ROOT_LABEL:upper(), { spacing = 3 })
    elseif query ~= "" then
        -- Search results
        ev[#ev + 1] = text(D.x + 14, RULER, 1, 11, FL[2],
            (#results == 0 and "NO MATCHES" or (#results >= 500 and "500+ MATCHES" or (#results == 1 and "1 MATCH" or (#results .. " MATCHES"))))
            .. "  ·  ESC CLEARS  ·  →  SHOWS IN COLUMNS", { spacing = 2 })
        ev[#ev + 1] = shape(rect_path(D.x + 14, RULER + 6, D.w - 28, 1), FL[3])
        res_top = math.max(0, math.min(res_top, #results - ROWS))
        for r = 1, ROWS do
            local i = res_top + r
            local e = results[i]
            if not e then break end
            local y = ROW0 + (r - 1) * ROW
            draw_row(ev, FL, e, D.x + 8, y, D.w - 16, i == res_sel, true, true)
            hits[#hits + 1] = { x = D.x, y = y, w = D.w, h = ROW, res = i }
        end
    else
        -- Columns
        local first, last = visible_range()
        local x = D.x + 6
        local cwall = D.w - 12
        ev[#ev + 1] = shape(rect_path(D.x + 14, RULER + 6, D.w - 28, 1), FL[3])
        for s = 1, 4 do
            local cw = cwall * SLOTS[s]
            local li = first + s - 1
            if s > 1 then ev[#ev + 1] = shape(rect_path(x - 0.5, RULER + 10, 1, bottom - RULER - 10), FL[3]) end
            local l = levels[li]
            if l and li <= last then
                local n = l.node
                ev[#ev + 1] = text(x + 10, RULER, 1, 11, li == focus and FL[1] or FL[2],
                    (n.label:upper()) .. "  ·  " .. #n.entries,
                    { spacing = 2, clip = { x, D.y + 36, cw - 10, 30 } })
                l.top = math.max(0, math.min(l.top, #n.entries - ROWS))
                for r = 1, ROWS do
                    local i = l.top + r
                    local e = n.entries[i]
                    if not e then break end
                    local y = ROW0 + (r - 1) * ROW
                    draw_row(ev, FL, e, x, y, cw, i == l.sel, li == focus, false)
                    hits[#hits + 1] = { x = x, y = y, w = cw, h = ROW, level = li, idx = i }
                end
                if #n.entries > ROWS then                  -- scroll position
                    local th = math.max(16, ROWS * ROW * ROWS / #n.entries)
                    local ty = ROW0 + (ROWS * ROW - th) * l.top / (#n.entries - ROWS)
                    ev[#ev + 1] = shape(rrect_path(x + cw - 4, ty, 3, th, 1.5), FL[2])
                end
                hits[#hits + 1] = { x = x, y = RULER - 10, w = cw, h = bottom - RULER + 10, column = li }
            end
            x = x + cw
        end
    end

    -- Details of the selection: where it is, how long, its format; notices
    ev[#ev + 1] = shape(rrect_path(DET.x, DET.y, DET.w, DET.h, 6), FL[3], 120)
    local tw = BUTTONS[1].x - DET.x - 28
    if cur then
        ev[#ev + 1] = text(DET.x + 16, DET.y + 22, 4, 22, FL[1], cur.label,
            { bold = true, clip = { DET.x, DET.y, tw + 16, 44 } })
        local crumbs = { ROOT_LABEL:upper() }
        for part in cur.path:sub(#ROOT + 2):gmatch("[^/]+") do crumbs[#crumbs + 1] = part:upper() end
        crumbs[#crumbs] = nil                         -- (its own name is the heading)
        ev[#ev + 1] = text(DET.x + 16, DET.y + 47, 4, 12, FL[2], table.concat(crumbs, "  ›  "),
            { spacing = 1.5, clip = { DET.x, DET.y, tw + 16, DET.h } })
        local info, fmt, hires = {}, nil, false
        if cur.dir then
            info[#info + 1] = plural(cur.count)
        else
            local d = duration(cur)
            if d ~= "" then info[#info + 1] = d end
            fmt, hires = format_of(cur)
            if fmt then info[#info + 1] = fmt end
        end
        if playing_in(cur) then info[#info + 1] = cur.dir and "PLAYING FROM HERE" or "PLAYING" end
        local line = table.concat(info, "  ·  ")
        ev[#ev + 1] = text(DET.x + 16, DET.y + 71, 4, 15, FL[2], line, { clip = { DET.x, DET.y, tw + 16, DET.h } })
        if hires then
            local lx = DET.x + 16 + #line * 7.6 + 18
            ev[#ev + 1] = shape(circle_path(lx, DET.y + 71, 6), FL[1], 150, 5)
            ev[#ev + 1] = shape(circle_path(lx, DET.y + 71, 3.2), FL[1])
            ev[#ev + 1] = text(lx + 10, DET.y + 71, 4, 11, FL[1], "HI-RES", { spacing = 2, bold = true })
        end
    end
    if notice.text and mp.get_time() < notice.until_t then   -- over the details' heading
        ev[#ev + 1] = shape(rrect_path(DET.x + 6, DET.y + 4, tw + 14, 36, 4), C.window)
        ev[#ev + 1] = text(DET.x + 16, DET.y + 22, 4, 17, FL[1], notice.text,
            { bold = true, spacing = 1.5, clip = { DET.x, DET.y, tw + 16, 50 } })
    end

    -- Buttons (in the display, like a touch screen)
    for _, b in ipairs(BUTTONS) do
        local enabled = (b.label == "RESCAN" or b.label == "CLOSE")
            or (b.label == "ADD ALL" and (query ~= "" or (levels[focus] and levels[focus].node ~= tree)))
            or (b.label ~= "ADD ALL" and cur ~= nil)
        local down = pressed.id == b.label and mp.get_time() < pressed.until_t
        ev[#ev + 1] = shape(rrect_path(b.x, b.y, BW, BH, 5), enabled and FL[2] or FL[3])
        ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 1.5, BW - 3, BH - 3, 4), down and FL[3] or C.window)
        ev[#ev + 1] = text(b.x + BW / 2, b.y + 13, 5, 12.5, enabled and FL[1] or FL[3], b.label,
            { bold = true, spacing = 1 })
        ev[#ev + 1] = text(b.x + BW / 2, b.y + 26, 5, 7, enabled and FL[2] or FL[3], b.sub, { spacing = 0.3 })
        if enabled then hits[#hits + 1] = { x = b.x, y = b.y, w = BW, h = BH, btn = b.label } end
    end

    -- Dimmed while another window is active, as the guide
    if mp.get_property_bool("focused", true) == false then
        ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), "#000000", 178)
    end

    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------

local function read_saved()
    local f = io.open(SEL_FILE, "r")
    local p = f and f:read("*l")
    if f then f:close() end
    return p
end

rescan = function()
    if scanning then return end
    scanning = true
    local keep = (tree and current() and current().path) or read_saved()
    if tree then say("SCANNING  " .. ROOT_LABEL:upper()) end
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "find", ROOT .. "/", "(", "-name", ".*", "-o", "-name", "*.band", "-o", "-name", "*.logicx",
                 "-o", "-name", "*.musiclibrary", "-o", "-name", "*.photoslibrary", ")", "-prune",
                 "-o", "-type", "f", "-print" },
    }, function(_, r)
        scanning = false
        local out = (r and r.stdout) or ""
        out = out:gsub("//+", "/")
        if out == "" and not utils.file_info(ROOT) then
            scan_error = "MUSIC FOLDER NOT FOUND:  " .. ROOT_LABEL:upper()
            render()
            return
        end
        tree = build(out)
        if query ~= "" then do_search() end
        reveal(keep)
        if #levels == 1 and not levels[1].sel and #tree.entries > 0 then choose(1, 1, true) end
        probe_visible()
        if notice.text and notice.text:match("^SCANNING") then
            say(plural(tree.count) .. "  IN  " .. ROOT_LABEL:upper())
        end
        render()
    end)
    render()
end

---------------------------------------------------------------------------
-- Mouse and keys
---------------------------------------------------------------------------

local function grid_mouse()
    local m = mp.get_property_native("mouse-pos") or {}
    return ((m.x or -1) - OX) / S, ((m.y or -1) - OY) / S
end

local function inside(x, y, r, w, h)
    return x >= r.x and x <= r.x + (w or r.w) and y >= r.y and y <= r.y + (h or r.h)
end

local function hit_at(x, y)
    for _, t in ipairs(hits) do
        if not t.column and not t.btn and inside(x, y, t) then return t end
    end
end

local function press(id, fn)
    pressed.id, pressed.until_t = id, mp.get_time() + 0.15
    render()
    mp.add_timeout(0.16, function() render() end)
    fn()
end

local clicked_play = 0                               -- when a click last played a folder

mp.add_forced_key_binding("MBTN_LEFT", "lib-click", function(ev)
    if ev.event ~= "down" then return end                -- act on press, not release
    local x, y = grid_mouse()
    for _, t in ipairs(hits) do
        if t.btn and inside(x, y, t) then press(t.btn, ACTIONS[t.btn]); return end
    end
    if inside(x, y, SEARCH) then
        search_focus = true
        render()
        return
    end
    for k = 1, 27 do                                  -- A-Z
        local cx = AZ.x + (k - 1) * AZ.pitch
        if math.abs(x - cx) <= AZ.pitch / 2 and math.abs(y - AZ.y) <= 14 then
            local ch = ("ABCDEFGHIJKLMNOPQRSTUVWXYZ#"):sub(k, k)
            local list, set = nil, nil
            if query ~= "" then
                list = results
                set = function(i) res_sel = i; res_top = math.max(0, i - 1); probe_visible(); render() end
            elseif levels[focus] then
                list = levels[focus].node.entries
                set = function(i) choose(focus, i) end
            end
            for i, e in ipairs(list or {}) do
                local c = e.label:sub(1, 1):upper()
                if (ch == "#" and not c:match("%a")) or c >= ch and ch ~= "#" then set(i); break end
            end
            return
        end
    end
    local t = hit_at(x, y)
    if t then
        search_focus = false
        if t.res then
            res_sel = t.res
            probe_visible()
            render()
        else
            choose(t.level, t.idx)
            local e = levels[t.level] and levels[t.level].node.entries[t.idx]
            if e and e.dir and e.leaf then           -- a folder of tracks: play it
                add(e, "play")
                clicked_play = mp.get_time()
            end
        end
        return
    end
    if not inside(x, y, D) then
        search_focus = false
        render()
        pcall(mp.commandv, "begin-vo-dragging")      -- drag the window by its front panel
    end
end, { complex = true })

-- Double-click plays a track, or a folder of tracks (mpv's own
-- double-click, full screen, is replaced with keybind)
mp.commandv("keybind", "MBTN_LEFT_DBL", "script-message library-double-click")
mp.register_script_message("library-double-click", function()
    local t = hit_at(grid_mouse())
    if not t then return end
    local e = t.res and results[t.res] or (levels[t.level] and levels[t.level].node.entries[t.idx])
    if not e then return end
    if t.res and e.dir then go_right()
    elseif e.dir and e.leaf and mp.get_time() - clicked_play < 1 then return   -- its click played it
    elseif not e.dir or e.leaf then add(e, "play") end
end)

local function wheel(d)
    return function()
        local x, y = grid_mouse()
        if query ~= "" then
            res_top = math.max(0, math.min(res_top + d, #results - ROWS))
            probe_visible()
            redraw_soon()
            return
        end
        for _, t in ipairs(hits) do
            if t.column and inside(x, y, t) then
                local l = levels[t.column]
                l.top = math.max(0, math.min(l.top + d, #l.node.entries - ROWS))
                redraw_soon()
                return
            end
        end
    end
end
mp.add_forced_key_binding("WHEEL_UP", "lib-wheel-up", wheel(-1))
mp.add_forced_key_binding("WHEEL_DOWN", "lib-wheel-down", wheel(1))

local function key(name, fn) mp.add_forced_key_binding(name, "lib-" .. name, fn, { repeatable = true }) end
key("UP", function() move(-1) end)
key("DOWN", function() move(1) end)
key("PGUP", function() move(-ROWS) end)
key("PGDWN", function() move(ROWS) end)
key("HOME", function() move(-100000) end)
key("END", function() move(100000) end)
key("RIGHT", go_right)
key("LEFT", go_left)
key("Alt+DOWN", go_right)                             -- knob 1 with Alt: change column
key("Alt+UP", function() if query == "" then go_left() end end)
key("ENTER", open_or_play)
key("KP_ENTER", open_or_play)
key("Alt+ENTER", function() add(current(), "end") end)
key("TAB", function()
    if query == "" then if focus < #levels then go_right() else focus = 1; render() end end
end)
key("ESC", function()
    if search_focus or query ~= "" then search_focus = false; set_query("") end
end)
key("/", function() search_focus = true; render() end)
key("Meta+f", function() search_focus = true; render() end)
key("BS", function()
    if query ~= "" then
        set_query(query:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""))
    elseif search_focus then
        search_focus = false
        render()
    else
        go_left()
    end
end)

-- Typing: into the search box, or jump to a name in the column
local function typed(ch)
    if search_focus or query ~= "" then
        search_focus = true
        set_query(query .. ch)
        return
    end
    local l = levels[focus]
    if not l then return end
    local now = mp.get_time()
    jump.buf = (now - jump.t > 1.2) and ch or (jump.buf .. ch)
    jump.t = now
    local want = jump.buf:lower()
    for i, e in ipairs(l.node.entries) do
        if e.label:lower():sub(1, #want) == want then choose(focus, i); return end
    end
end
local CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-'&.,!()"
for k = 1, #CHARS do
    local ch = CHARS:sub(k, k)
    mp.add_forced_key_binding(ch, "lib-char-" .. k, function() typed(ch) end, { repeatable = true })
    if ch:match("%a") then
        mp.add_forced_key_binding(ch:upper(), "lib-char-u" .. k, function() typed(ch:upper()) end,
            { repeatable = true })
    end
end
mp.add_forced_key_binding("SPACE", "lib-space", function() typed(" ") end)

-- Pad keys 1-8 and Alt + keys act on the player, as on the faceplate
local function pad(k, ...)
    local c = { ... }
    mp.add_forced_key_binding(k, "lib-pad-" .. k, function() send(c) end)
end
for i = 1, 8 do pad("F" .. (12 + i), "script-message", "music-play", tostring(i)) end
pad("Alt+F16", "cycle", "mute")
pad("Alt+F19", "quit")
pad("Alt+F20", "cycle", "fullscreen")
mp.add_forced_key_binding("Alt+F17", "lib-close", function() mp.command("quit") end)   -- Alt + 5: LIBRARY

---------------------------------------------------------------------------
-- Follow the player: highlight what's playing; close when it quits
---------------------------------------------------------------------------

mp.add_periodic_timer(0.5, function()
    local f = io.open(STATE, "r")
    local raw = f and f:read("*a")
    if f then f:close() end
    if raw and raw ~= last_raw then
        local s = utils.parse_json(raw)
        if s and (s.t or 0) >= started - 30 then
            last_raw = raw
            if s.closed then mp.command("quit"); return end
            if s.path ~= playing_path then playing_path = s.path; render() end
            last_t = s.t
        end
    end
    if last_t and os.time() - last_t > 6 then mp.command("quit") end   -- player gone
end)

mp.add_periodic_timer(1, function()
    local f = io.open(ALIVE, "w")
    if f then f:write(os.time(), "\n"); f:close() end
    local before = theme
    read_theme()
    if theme ~= before then render() end
end)

mp.register_event("shutdown", save_selection)
mp.observe_property("focused", "native", function(_, v) if v == false and search_focus and query == "" then
    search_focus = false; render() end end)

do                                                     -- somewhere to remember the selection
    local dir = SEL_FILE:match("(.*)/")
    if dir then utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false }) end
end
read_theme()
mp.observe_property("osd-dimensions", "native", function(_, d)
    if d then osd_w, osd_h = d.w or 0, d.h or 0 end
    render()
end)
mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
rescan()

-- Closing (CLOSE, Alt + 5, the player gone): tell the faceplate at once, so
-- its LIBRARY / GUIDE light goes out and the next press opens it again
mp.register_event("shutdown", function() os.remove(ALIVE) end)
