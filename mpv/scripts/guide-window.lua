-- guide-window.lua
-- The TV's programme guide (EG-252, control socket /tmp/mpv-lib-tv): its own
-- media-less mpv window, which Hammerspoon puts directly under the stack
-- (the faceplates' width, down to the bottom of the screen), opened and closed by
-- clicking the TV faceplate's display or the preamp's MONITOR GUIDE button,
-- drawn on the same brushed-black front as the faceplates.
--
--   A grid of the TV's channels (the TV player's playlist, numbered as the
--   pad's keys 1-8) against time, starting from now and going as far as
--   Tvheadend's EPG does (about a week). The selected programme's details
--   are underneath. Tvheadend does the recording, so the Mac needn't be on:
--   REC records the selected programme (a DVR entry), ALL EPISODES records
--   every episode (a series link, Tvheadend's autorec); press either again
--   to cancel. Programmes recording, scheduled or series-linked are marked
--   in red, whoever set them up.
--
--   Pad key 2 shows the recordings instead: what's recording and scheduled
--   (soonest first), then what's been recorded (newest first). WATCH plays
--   a recording on the TV (a channel key goes back to live), DELETE removes it from Tvheadend
--   (press twice), CANCEL REC / STOP REC and CANCEL ALL as in the guide.
--   Pad key 1 goes back to the guide.
--
--   Keys: arrows (knob 1, through Hammerspoon: Left / Right, along the
--   channel; knob 2: Up / Down, another channel or recording), Enter (knob
--   press) watches a programme that's on now or a recording, or records a
--   later programme, Alt + Enter records all episodes, PGUP / PGDN a day
--   (recordings: a page), Esc back to now. Click to select, double-click as
--   Enter; scroll moves along the channels.
--
--   The radio has the same guide (/tmp/mpv-lib-radio), for its stations.
--
--   Pad key 3 shows the presets: every channel on the Tvheadend server,
--   filtered by type (HD, SD, UHD, radio) or by Tvheadend's channel tags.
--   A knob press puts the selected one on the next free pad key (1-8), or
--   takes it off; RADIO's are the radio's keys, the rest the TV's. They're
--   saved in ~/.config/mpv-tvh/presets.json, and the TV and radio reload
--   their channels from them. Pad key 4 shows streams: internet radio and
--   TV links you keep (copy one, then press a knob to add it; type to name
--   it), which then show up in the presets with the rest. SETUP (from the
--   preamp, and the first time,
--   when there's no Tvheadend yet) asks for the server's address, finds it
--   on the network if it can, and checks it.
--
-- Talks to Tvheadend with curl (script-opt tvh-host; credentials, if your
-- Tvheadend needs them for the DVR, from ~/.netrc), and to the TV player
-- over /tmp/mpv-tv with nc. Writes /tmp/mpv-tv.lib.alive while open,
-- follows the TV faceplate's display colour, and closes when the TV quits.

local mp = require 'mp'
local utils = require 'mp.utils'

local KIND = (mp.get_property("input-ipc-server") or ""):match("/mpv%-lib%-(%a+)$")
if KIND ~= "tv" and KIND ~= "radio" then return end
local RADIO = KIND == "radio"

-- Presets and the Tvheadend address SETUP saved (they win over the config)
local PRESETS_FILE = (os.getenv("HOME") or "") .. "/.config/mpv-tvh/presets.json"
local function read_presets()
    local f = io.open(PRESETS_FILE, "r")
    local j = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    if type(j) ~= "table" then j = {} end
    j.tv, j.radio, j.streams = j.tv or {}, j.radio or {}, j.streams or {}
    return j
end
local function write_presets(p)
    mp.command_native({ name = "subprocess", playback_only = false,
        args = { "mkdir", "-p", (PRESETS_FILE:match("(.*)/")) } })
    local f = io.open(PRESETS_FILE .. ".tmp", "w")
    if not f then return false end
    f:write(utils.format_json(p), "\n")
    f:close()
    return os.rename(PRESETS_FILE .. ".tmp", PRESETS_FILE)
end

local TVH_HOST = read_presets().host or mp.get_opt("tvh-host") or ""
local DEMO = (mp.get_opt("tvh-demo") or "") ~= ""      -- not set up yet: the demo's playing
local SOCK       = "/tmp/mpv-" .. KIND
local STATE      = "/tmp/mpv-" .. KIND .. ".state.json"
local ALIVE      = "/tmp/mpv-" .. KIND .. ".lib.alive"
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
    rec = "#FF3B30",
}
local FONT = "Helvetica Neue"

---------------------------------------------------------------------------
-- Drawing (ASS), on a grid 880 wide, as tall as the window's shape makes it
---------------------------------------------------------------------------

local GW, GH = 880, 496
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
    r = math.min(r, w / 2, h / 2)
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

-- A ring: the outer circle, then the inner one drawn the other way round
local function ring_path(cx, cy, r, t)
    local ri = r - t
    local o = circle_path(cx, cy, r)
    local x, y = X(cx), Y(cy)
    local k, rr = N(ri) * 0.5523, N(ri)
    local inner = table.concat({
        "m", f1(x), f1(y - rr),
        "b", f1(x - k), f1(y - rr), f1(x - rr), f1(y - k), f1(x - rr), f1(y),
        "b", f1(x - rr), f1(y + k), f1(x - k), f1(y + rr), f1(x), f1(y + rr),
        "b", f1(x + k), f1(y + rr), f1(x + rr), f1(y + k), f1(x + rr), f1(y),
        "b", f1(x + rr), f1(y - k), f1(x + k), f1(y - rr), f1(x), f1(y - rr),
    }, " ") .. " "
    return o .. inner
end

local function shape(path, color, a, blur)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&\\blur%s\\p1}%s{\\p0}",
        col(color), a or 0, f1(N(blur or 0)), path)
end

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

local SPAN = 2 * 3600                                         -- hours across the grid
local CHW = 176                                               -- channel names
local RH = 46                                                 -- row pitch
local DET_MIN = 126                                           -- the details, at least
local BW, BH, BG = 150, 34, 7                                 -- the buttons, down the details' right
local BUTTONS = {
    { id = "watch",  label = KIND == "radio" and "LISTEN" or "WATCH", sub = "ENTER" },
    { id = "rec",    label = "REC",          sub = "ENTER, LATER ONES" },
    { id = "series", label = "ALL EPISODES", sub = "ALT + ENTER" },
}
local D, GX, GWID, RULER, ROW0, ROWS, DET

-- The grid fills the window's width; its height decides how many channel
-- rows fit above the details
local function layout()
    D = { x = 16, y = 42, w = GW - 32, h = GH - 42 - 16 }    -- the display window
    GX = D.x + CHW                                            -- the grid's left
    GWID = D.x + D.w - 14 - GX                                -- and width
    RULER = D.y + 50                                          -- time labels
    ROW0 = D.y + 62                                           -- first row
    ROWS = math.max(3, math.floor((D.y + D.h - 10 - DET_MIN - 10 - ROW0) / RH))
    DET = { x = D.x + 10, y = ROW0 + ROWS * RH + 10 }         -- the details: the rest
    DET.w, DET.h = D.w - 20, D.y + D.h - 10 - DET.y
    for k, b in ipairs(BUTTONS) do
        b.x = DET.x + DET.w - 8 - BW
        b.y = DET.y + 6 + (k - 1) * (BH + BG)
    end
end
layout()

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local backdrop = mp.create_osd_overlay("ass-events")
backdrop.z = -1
local overlay = mp.create_osd_overlay("ass-events")
local theme = "blue"                   -- the TV faceplate's, until its prefs say
local channels = {}                    -- { title, uuid, events = { ... } } in playlist order
local playing = 0                      -- the channel the TV's on (1-based)
local series_of = {}                   -- DVR entry uuid -> autorec uuid
local view0 = 0                        -- the grid's left edge (time)
local sel = { ch = 1, t = 0 }          -- selected channel and the time it's at
local top = 0                          -- first channel row shown
local notice = { text = nil, until_t = 0 }
local pressed = { id = nil, until_t = 0 }
local loading, load_error = true, nil
local started, last_raw, last_t = os.time(), nil, nil
local hits = {}
local view = "guide"                   -- "recs": the recordings (pad key 2); "presets" (3); "streams" (4); "setup"
local recs, rsel, rtop = {}, 1, 0      -- the recordings list, selected, first shown
local recs_loading, recs_error = false, nil
local confirm = { uuid = nil, until_t = 0 }   -- DELETE: press again to delete
-- Presets: Tvheadend's channels, the filters, the eight keys each for TV and radio
local lineup, lineup_loading, lineup_error = nil, false, nil
local tvh_lineup = nil                  -- Tvheadend's part of the lineup (the streams are added to it)
local ssel, stop_ = 1, 0                -- streams: selected, first shown
local adding, remove_confirm = false, 0
local FIXED_FILTERS = { "ALL", "HD", "SD", "UHD", "RADIO" }
local filters = { "ALL", "HD", "SD", "UHD", "RADIO" }   -- then Tvheadend's own tags
local filter = RADIO and "RADIO" or "ALL"
local psel, ptop = 1, 0
local presets = read_presets()
local presets_dirty = false
-- First setup: the keys are filled from Tvheadend's lineup (autofill), then
-- the presets walk through the TV's keys (wizard "tv") and the radio's
-- ("radio"): NEXT: RADIO, then DONE
local autofill, wizard = false, nil
local clear_confirm = 0
-- SETUP: the address being typed
local setup = { addr = "", finding = false, checking = false, first = false }
local osd_w, osd_h = 0, 0
local static = { w = 0, h = 0 }
local render

local function half_hour(t) return t - t % 1800 end
local function say(s, secs) notice.text, notice.until_t = s, mp.get_time() + (secs or 3); render() end

local function read_theme()
    local f = io.open(PREFS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local c = line:match("^colour=(%a+)$")
        if c and DISPLAYS[c] then theme = c end
    end
    f:close()
end

local redraw_timer
local function redraw_soon()
    if redraw_timer then return end
    redraw_timer = mp.add_timeout(1 / 60, function() redraw_timer = nil; render() end)
end

-- To the TV player, and to the preamp
local function send(sock, ...)
    local lines = {}
    for _, c in ipairs({ ... }) do lines[#lines + 1] = utils.format_json({ command = c }) end
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { "/bin/sh", "-c", 'printf "%s\\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1', "sh",
                 table.concat(lines, "\n"), sock },
    }, function() end)
end

---------------------------------------------------------------------------
-- Tvheadend
---------------------------------------------------------------------------

-- GET (or POST with form fields) api/<path>; calls back with the parsed
-- JSON (or nil) and the HTTP status
local function api(path, form, cb)
    local args = { "curl", "-sS", "--netrc-optional", "--max-time", "8", "-w", "\n%{http_code}" }
    for k, v in pairs(form or {}) do
        args[#args + 1] = "--data-urlencode"
        args[#args + 1] = k .. "=" .. v
    end
    args[#args + 1] = "http://" .. TVH_HOST .. "/api/" .. path
    mp.command_native_async({ name = "subprocess", args = args, capture_stdout = true,
                              playback_only = false }, function(ok, res)
        local out = ok and res and res.stdout or ""
        local body, code = out:match("^(.*)\n(%d+)$")
        cb(body and utils.parse_json(body), tonumber(code) or 0)
    end)
end

local function event_at(c, t)              -- the programme on channel c at time t
    for _, e in ipairs(c and c.events or {}) do
        if e.stop > t then return e end          -- on then, or the first after
    end
end

local function selected()
    return event_at(channels[sel.ch], math.max(sel.t, os.time()))
end

local function fetch_upcoming()
    api("dvr/entry/grid_upcoming?limit=2000", nil, function(j)
        series_of = {}
        for _, e in ipairs(j and j.entries or {}) do
            if e.uuid and e.autorec and e.autorec ~= "" then series_of[e.uuid] = e.autorec end
        end
        render()
    end)
end

local function fetch_events()
    if TVH_HOST == "" then loading, load_error = false, "NEEDS TVHEADEND  ·  TVHEADEND.ORG"; render(); return end
    local pending = 0
    for _, c in ipairs(channels) do
        if c.uuid then
            pending = pending + 1
            api("epg/events/grid?limit=1000&sort=start&dir=ASC&channel=" .. c.uuid, nil, function(j, code)
                pending = pending - 1
                if j and j.entries then
                    local evs = {}
                    for _, e in ipairs(j.entries) do
                        if e.start and e.stop and e.stop > os.time() then evs[#evs + 1] = e end
                    end
                    table.sort(evs, function(a, b) return a.start < b.start end)
                    c.events = evs
                    load_error = nil
                elseif code ~= 200 then
                    load_error = code == 0 and "CAN'T REACH TVHEADEND" or ("TVHEADEND SAYS " .. code)
                end
                if pending == 0 then loading = false end
                render()
            end)
        end
    end
    if pending == 0 then loading = false; render() end
    fetch_upcoming()
end

-- The TV's channels: its playlist (titles and Tvheadend stream URLs)
local function fetch_channels(then_)
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "/bin/sh", "-c",
                 'printf \'{"command":["get_property","playlist"]}\\n\' | nc -U -w 1 "$1"', "sh", SOCK },
    }, function(ok, res)
        local j = ok and res and utils.parse_json(((res.stdout or ""):match("[^\n]+")) or "")
        local list = j and j.data
        if type(list) ~= "table" then return end
        local before = {}
        for _, c in ipairs(channels) do before[c.uuid or c.title] = c.events end
        channels = {}
        for i, e in ipairs(list) do
            if not (e.filename or ""):find("/dvrfile/", 1, true) then   -- not a recording playing
                local uuid = (e.filename or ""):match("/stream/channel/(%w+)")
                channels[#channels + 1] = { title = e.title or e.filename, uuid = uuid,
                                            events = before[uuid or e.title] or {} }
                if e.current or e.playing then playing = i end
            end
        end
        if then_ then then_() end
        render()
    end)
end

---------------------------------------------------------------------------
-- Moving about
---------------------------------------------------------------------------

local function keep_visible()
    local e = selected()
    local now0 = half_hour(os.time())
    if e then
        local s = math.max(e.start, now0)
        if s < view0 then view0 = half_hour(s)
        elseif s >= view0 + SPAN - 1800 then view0 = math.max(now0, half_hour(s) - 1800) end
    end
    if view0 < now0 then view0 = now0 end
    if sel.ch <= top then top = sel.ch - 1 end
    if sel.ch > top + ROWS then top = sel.ch - ROWS end
    top = math.max(0, math.min(top, #channels - ROWS))
end

local function along(d)                    -- the next or previous programme on the channel
    local c, e = channels[sel.ch], selected()
    if not c or not e then return end
    for i, x in ipairs(c.events) do
        if x == e then
            local n = c.events[i + d]
            if n and n.stop > os.time() then sel.t = math.max(n.start, os.time()) end
            break
        end
    end
    keep_visible()
    redraw_soon()
end

local function across(d)                   -- another channel, at the same time
    if #channels == 0 then return end
    sel.ch = math.max(1, math.min(#channels, sel.ch + d))
    local e = selected()
    if e then sel.t = math.max(sel.t, e.start, os.time()) end
    keep_visible()
    redraw_soon()
end

local function to_time(t)                  -- PGUP / PGDN: a day; Esc: now
    sel.t = math.max(os.time(), t)
    local e = selected()
    if e then sel.t = math.max(e.start, os.time()) end
    view0 = half_hour(math.max(os.time(), t))
    keep_visible()
    render()
end

---------------------------------------------------------------------------
-- Watching and recording
---------------------------------------------------------------------------

local function on_now(e) local n = os.time(); return e and e.start <= n and e.stop > n end

local function watch()
    if not channels[sel.ch] then return end
    send(SOCK, { "playlist-play-index", tostring(sel.ch - 1) })
    send("/tmp/mpv-preamp", { "script-message", "preamp-select", RADIO and "tuner" or "tv" })
    playing = sel.ch
    say((RADIO and "LISTENING TO  " or "WATCHING  ") .. (channels[sel.ch].title or ""):upper(), 2)
end

local function refresh_soon() mp.add_timeout(1, fetch_events) end

local function done(what)
    return function(_, code)
        if code == 200 then say(what, 3); refresh_soon()
        elseif code == 401 or code == 403 then say("TVHEADEND WON'T LET US RECORD: SEE ~/.netrc", 6)
        else say(code == 0 and "CAN'T REACH TVHEADEND" or ("TVHEADEND SAYS " .. code), 5) end
    end
end

local function rec_toggle()
    local e = selected()
    if not e then return end
    if e.dvrUuid and (e.dvrState == "scheduled" or e.dvrState == "recording") then
        if e.dvrState == "recording" then
            api("dvr/entry/stop", { uuid = e.dvrUuid }, done("RECORDING STOPPED"))
        else
            api("idnode/delete", { uuid = e.dvrUuid }, done("RECORDING CANCELLED"))
        end
    else
        api("dvr/entry/create_by_event", { event_id = tostring(e.eventId), config_uuid = "" },
            done(on_now(e) and "RECORDING  " .. (e.title or "") or "WILL RECORD  " .. (e.title or "")))
    end
end

local function series_toggle()
    local e = selected()
    if not e then return end
    local rule = e.dvrUuid and series_of[e.dvrUuid]
    if rule then
        api("idnode/delete", { uuid = rule }, done("NO LONGER RECORDING ALL EPISODES"))
    else
        api("dvr/autorec/create_by_series", { event_id = tostring(e.eventId), config_uuid = "" },
            done("RECORDING ALL EPISODES  " .. (e.title or "")))
    end
end

local function enter()
    local e = selected()
    if on_now(e) or not e then watch() else rec_toggle() end
end

local ACTIONS = { watch = watch, rec = rec_toggle, series = series_toggle }

---------------------------------------------------------------------------
-- Recordings (pad key 2): Tvheadend's DVR entries
---------------------------------------------------------------------------

local function fetch_recs()
    if TVH_HOST == "" then recs_error = "NEEDS TVHEADEND  ·  TVHEADEND.ORG"; render(); return end
    recs_loading = true
    local up, done_, pending = nil, nil, 2
    local function finish()
        pending = pending - 1
        if pending > 0 then return end
        recs_loading = false
        if not up and not done_ then recs_error = "CAN'T REACH TVHEADEND"; render(); return end
        recs_error = nil
        local keep = recs[rsel] and recs[rsel].uuid
        local now_, later, past = {}, {}, {}
        local function entry(e, state)
            return { uuid = e.uuid, state = state, autorec = (e.autorec or "") ~= "" and e.autorec or nil,
                     title = e.disp_title or "", subtitle = e.disp_subtitle or "",
                     desc = e.disp_description or e.disp_extratext or "",
                     channel = e.channelname or "", start = e.start_real or e.start or 0,
                     stop = e.stop_real or e.stop or 0, size = tonumber(e.filesize) or 0,
                     status = e.status or "" }
        end
        for _, e in ipairs(up or {}) do
            if e.sched_status == "recording" then now_[#now_ + 1] = entry(e, "recording")
            elseif e.sched_status == "scheduled" then later[#later + 1] = entry(e, "scheduled") end
        end
        for _, e in ipairs(done_ or {}) do past[#past + 1] = entry(e, "recorded") end
        table.sort(later, function(a, b) return a.start < b.start end)
        table.sort(past, function(a, b) return a.start > b.start end)
        recs = {}
        for _, l in ipairs({ now_, later, past }) do for _, e in ipairs(l) do recs[#recs + 1] = e end end
        rsel = 1
        for i, e in ipairs(recs) do if e.uuid == keep then rsel = i end end
        render()
    end
    api("dvr/entry/grid_upcoming?limit=1000", nil, function(j) up = j and j.entries; finish() end)
    api("dvr/entry/grid_finished?limit=1000", nil, function(j) done_ = j and j.entries; finish() end)
end

local function rec_selected() return recs[rsel] end

local function recs_visible()
    rsel = math.max(1, math.min(#recs, rsel))
    if rsel <= rtop then rtop = rsel - 1 end
    if rsel > rtop + ROWS then rtop = rsel - ROWS end
    rtop = math.max(0, math.min(rtop, #recs - ROWS))
end

local function rmove(d)
    if #recs == 0 then return end
    rsel = rsel + d
    recs_visible()
    redraw_soon()
end

local fetch_lineup, apply_presets, merge_lineup, svisible   -- (below)
local function show(v)                     -- pad keys 1, 2 and 3; SETUP
    if view == "setup" and TVH_HOST == "" and (v == "guide" or v == "recs") then return end   -- needs an address first
    if view == v then return end
    if view == "presets" or view == "streams" then apply_presets() end
    if v ~= "presets" then wizard = nil end
    view = v
    if v == "recs" then fetch_recs() end
    if v == "presets" then presets = read_presets(); if not tvh_lineup then fetch_lineup() else merge_lineup() end end
    if v == "streams" then presets = read_presets(); svisible() end
    if v == "setup" then setup.addr = TVH_HOST end
    render()
end

local function rdone(what)
    return function(_, code)
        if code == 200 then say(what, 3); mp.add_timeout(1, function() fetch_recs(); fetch_upcoming() end)
        elseif code == 401 or code == 403 then say("TVHEADEND WON'T LET US: SEE ~/.netrc", 6)
        else say(code == 0 and "CAN'T REACH TVHEADEND" or ("TVHEADEND SAYS " .. code), 5) end
    end
end

-- WATCH: in the TV window (the preamp switches to the TV, starting it if
-- it isn't running), streamed from Tvheadend; a channel key goes back to
-- live (player-state.lua)
local function tv_running()
    local f = io.open("/tmp/mpv-tv.state.json", "r")
    local s = f and utils.parse_json(f:read("*a") or "")
    if f then f:close() end
    return s and s.t and os.time() - s.t < 6 and not s.closed
end

local function rwatch()
    local e = rec_selected()
    if not e or e.state == "scheduled" then return end
    local url = "http://" .. TVH_HOST .. "/dvrfile/" .. e.uuid
    local wait = tv_running() and 0.1 or 4
    send("/tmp/mpv-preamp", { "script-message", "preamp-select", "tv" })
    mp.add_timeout(wait, function() send("/tmp/mpv-tv", { "script-message", "tvh-recording", url, e.title or "", e.channel or "" }) end)
    say("PLAYING  " .. e.title, 3)
end

local function rrec()                      -- DELETE (twice), CANCEL REC, STOP REC
    local e = rec_selected()
    if not e then return end
    if e.state == "recording" then
        api("dvr/entry/stop", { uuid = e.uuid }, rdone("RECORDING STOPPED"))
    elseif e.state == "scheduled" then
        api("idnode/delete", { uuid = e.uuid }, rdone("RECORDING CANCELLED"))
    elseif confirm.uuid == e.uuid and mp.get_time() < confirm.until_t then
        confirm.uuid = nil
        api("dvr/entry/remove", { uuid = e.uuid }, rdone("DELETED  " .. e.title))
    else
        confirm.uuid, confirm.until_t = e.uuid, mp.get_time() + 4
        say("DELETE  " .. e.title .. "?  PRESS AGAIN", 4)
        mp.add_timeout(4.1, render)
    end
end

local function rseries()                   -- CANCEL ALL: the series link it came from
    local e = rec_selected()
    if not e or not e.autorec then return end
    api("idnode/delete", { uuid = e.autorec }, rdone("NO LONGER RECORDING ALL EPISODES"))
end

local function renter()
    local e = rec_selected()
    if e and e.state ~= "scheduled" then rwatch() end
end

local RACTIONS = { watch = rwatch, rec = rrec, series = rseries }

---------------------------------------------------------------------------
-- Presets (pad key 3)
---------------------------------------------------------------------------

-- Tvheadend's service types: radio, SD, HD, UHD
local RADIO_TYPES = { [2] = true, [10] = true }
local HD_TYPES = { [17] = true, [25] = true, [26] = true, [27] = true }
local UHD_TYPES = { [31] = true, [32] = true }

local function slots() return filter == "RADIO" and presets.radio or presets.tv end

local function filtered()
    local out = {}
    for _, c in ipairs(lineup or {}) do
        local ok
        if filter == "ALL" then ok = not c.radio
        elseif filter == "RADIO" then ok = c.radio
        elseif filter == "HD" then ok = c.kind == "HD"
        elseif filter == "SD" then ok = c.kind == "SD"
        elseif filter == "UHD" then ok = c.kind == "UHD"
        else ok = c.tags[filter] end
        if ok then out[#out + 1] = c end
    end
    return out
end

-- The lineup: Tvheadend's channels, then the streams
merge_lineup = function()
    lineup = {}
    for _, c in ipairs(tvh_lineup or {}) do lineup[#lineup + 1] = c end
    for _, st in ipairs(presets.streams) do
        lineup[#lineup + 1] = { id = st.url, url = st.url, title = st.title or st.url, number = 0,
                                radio = st.radio ~= false, tags = {}, kind = "STREAM" }
    end
end

-- Every channel: its number, name, type and tags
fetch_lineup = function()
    if TVH_HOST == "" then merge_lineup(); render(); return end
    lineup_loading, lineup_error = true, nil
    local chans, svcs, tags, pending = nil, nil, nil, 3
    local function finish()
        pending = pending - 1
        if pending > 0 then return end
        lineup_loading = false
        if not chans then lineup_error = "CAN'T REACH TVHEADEND"; merge_lineup(); render(); return end
        local stype, tagname = {}, {}
        for _, v in ipairs(svcs or {}) do stype[v.uuid or ""] = tonumber(v.dvb_servicetype) end
        for _, t in ipairs(tags or {}) do
            if t.enabled ~= false and t.name and t.name ~= "" then tagname[t.uuid] = t.name end
        end
        local tl = {}
        local used = {}
        for _, c in ipairs(chans) do
            if c.enabled ~= false and c.uuid then
                local t
                for _, su in ipairs(c.services or {}) do t = t or stype[su] end
                local ctags, radio = {}, t and RADIO_TYPES[t] or false
                for _, tu in ipairs(c.tags or {}) do
                    local n = tagname[tu]
                    if n then
                        ctags[n] = true
                        used[n] = true
                        if n:lower():find("radio") then radio = true end
                    end
                end
                tl[#tl + 1] = { id = c.uuid, uuid = c.uuid, title = c.name or "", number = tonumber(c.number) or 0,
                    radio = radio, tags = ctags,
                    kind = radio and "RADIO" or (t and UHD_TYPES[t] and "UHD") or (t and HD_TYPES[t] and "HD") or "SD" }
            end
        end
        table.sort(tl, function(a, b)
            if a.number ~= b.number then return (a.number == 0 and 1e9 or a.number) < (b.number == 0 and 1e9 or b.number) end
            return a.title:lower() < b.title:lower()
        end)
        -- Tvheadend's own tags, after the types (not its type-based ones)
        filters = {}
        for _, f in ipairs(FIXED_FILTERS) do filters[#filters + 1] = f end
        local extra = {}
        for n in pairs(used) do
            local l = n:lower()
            if not (l:find("radio") or l:match("^tv channels") or l:match("^hdtv") or l:match("^sdtv")
                    or l:match("^uhdtv")) then extra[#extra + 1] = n end
        end
        table.sort(extra)
        for _, n in ipairs(extra) do filters[#filters + 1] = n end
        tvh_lineup = tl
        merge_lineup()
        if autofill then
            autofill = false
            -- The first eight of each, in Tvheadend's channel order
            presets = read_presets()
            local tv, radio = {}, {}
            for _, c in ipairs(tl) do
                local list = c.radio and radio or tv
                if #list < 8 then list[#list + 1] = { uuid = c.uuid, title = c.title } end
            end
            if #presets.tv == 0 then presets.tv = tv end
            if #presets.radio == 0 then presets.radio = radio end
            write_presets(presets)
            presets_dirty = true
            say(string.format("%d TV CHANNELS AND %d RADIO STATIONS ON THE KEYS  ·  CHANGE ANY HERE",
                #presets.tv, #presets.radio), 6)
        end
        render()
    end
    api("channel/grid?limit=5000", nil, function(j) chans = j and j.entries; finish() end)
    api("mpegts/service/grid?limit=20000", nil, function(j) svcs = j and j.entries; finish() end)
    api("channeltag/grid?limit=1000", nil, function(j) tags = j and j.entries; finish() end)
end

local function pvisible()
    local n = #filtered()
    psel = math.max(1, math.min(n, psel))
    if psel <= ptop then ptop = psel - 1 end
    if psel > ptop + ROWS then ptop = psel - ROWS end
    ptop = math.max(0, math.min(ptop, n - ROWS))
end

local function pmove(d) psel = psel + d; pvisible(); redraw_soon() end

local function pfilter(d)                  -- knob 1: the next filter along
    local i = 1
    for k, f in ipairs(filters) do if f == filter then i = k end end
    filter = filters[(i - 1 + d) % #filters + 1]
    psel, ptop = 1, 0
    render()
end

local function slot_of(list, id)                -- a key holds a Tvheadend channel (uuid) or a stream (url)
    for k, e in ipairs(list) do if (e.uuid or e.url) == id then return k end end
end

-- The TV and radio take their channels from the presets again
apply_presets = function()
    if not presets_dirty then return end
    presets_dirty = false
    mp.command_native_async({ name = "subprocess", playback_only = false, detach = true,
        args = { "fish", "-c", "__tvh tv --reload; __tvh radio --reload" } }, function() end)
    mp.add_timeout(2.5, function() fetch_channels(function() fetch_events() end) end)
end

local function ptoggle()                   -- a knob press: on the next free key, or off
    local c = filtered()[psel]
    if not c then return end
    local list = slots()
    local k = slot_of(list, c.id)
    if k then
        table.remove(list, k)
        say("OFF KEY " .. k .. "  ·  " .. c.title:upper(), 2)
    elseif #list >= 8 then
        say("ALL 8 KEYS USED: TAKE ONE OFF FIRST", 3)
        return
    else
        list[#list + 1] = c.url and { url = c.url, title = c.title } or { uuid = c.uuid, title = c.title }
        say("KEY " .. #list .. "  ·  " .. c.title:upper(), 2)
    end
    write_presets(presets)
    presets_dirty = true
end

local function pclear()                    -- CLEAR: these eight keys (press twice)
    if mp.get_time() > clear_confirm then
        clear_confirm = mp.get_time() + 4
        say("CLEAR ALL " .. (filter == "RADIO" and "RADIO" or "TV") .. " KEYS?  PRESS AGAIN", 4)
        mp.add_timeout(4.1, render)
        return
    end
    clear_confirm = 0
    if filter == "RADIO" then presets.radio = {} else presets.tv = {} end
    write_presets(presets)
    presets_dirty = true
    say("KEYS CLEARED", 2)
end

---------------------------------------------------------------------------
-- SETUP: where Tvheadend is
---------------------------------------------------------------------------

local function normal_addr(a)
    a = (a or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://", ""):gsub("/.*$", "")
    if a ~= "" and not a:find(":") then a = a .. ":9981" end
    return a
end

local function sconnect()
    local a = normal_addr(setup.addr)
    if a == "" then say("TYPE TVHEADEND'S ADDRESS FIRST", 3); return end
    setup.checking = true
    render()
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "curl", "-sS", "--netrc-optional", "--max-time", "5", "-w", "\n%{http_code}",
                 "http://" .. a .. "/api/serverinfo" } }, function(ok, res)
        setup.checking = false
        local out = ok and res and res.stdout or ""
        local body, code = out:match("^(.*)\n(%d+)$")
        local j = body and utils.parse_json(body)
        if tonumber(code) ~= 200 or not j then
            say(tonumber(code or 0) == 0 and ("NOTHING ANSWERS AT  " .. a:upper()) or ("NOT TVHEADEND?  IT SAYS " .. code), 5)
            return
        end
        local changed = a ~= TVH_HOST
        TVH_HOST = a
        presets = read_presets()
        presets.host = a
        write_presets(presets)
        say("CONNECTED  ·  TVHEADEND " .. (j.sw_version or ""):upper(), 4)
        if changed then presets_dirty = true end
        lineup = nil
        if #presets.tv == 0 and #presets.radio == 0 then
            autofill, wizard = true, "tv"
            filter, psel, ptop = "ALL", 1, 0
            view = "presets"; fetch_lineup()
        else
            apply_presets()
            view = "guide"; fetch_events()
        end
        render()
    end)
end

-- FIND: Tvheadend announces itself on the network (Bonjour, _htsp._tcp);
-- its web port is the one before HTSP's
local function sfind()
    if setup.finding then return end
    setup.finding = true
    render()
    local sh = [=[
command -v dns-sd >/dev/null || exit 0
dns-sd -B _htsp._tcp local. > /tmp/mpv-tvh-find.txt 2>/dev/null & p=$!; sleep 2; kill $p 2>/dev/null
name=$(sed -n 's/.*_htsp\._tcp\.[[:space:]]*//p' /tmp/mpv-tvh-find.txt | head -1)
[ -n "$name" ] || exit 0
dns-sd -L "$name" _htsp._tcp local. > /tmp/mpv-tvh-find.txt 2>/dev/null & p=$!; sleep 2; kill $p 2>/dev/null
sed -n 's/.*can be reached at \([^ ]*\)\.:\([0-9]*\).*/ /p' /tmp/mpv-tvh-find.txt | head -1
rm -f /tmp/mpv-tvh-find.txt]=]
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "/bin/sh", "-c", sh } }, function(ok, res)
        setup.finding = false
        local h, port = ((ok and res and res.stdout) or ""):match("(%S+) (%d+)")
        if h then
            setup.addr = h .. ":" .. (tonumber(port) - 1)
            say("FOUND TVHEADEND  ·  CONNECT TO CHECK IT", 4)
        else
            say("NO TVHEADEND FOUND ON THE NETWORK: TYPE ITS ADDRESS", 5)
        end
    end)
end

local function scancel()
    if TVH_HOST == "" then mp.command("quit"); return end   -- DEMO, or CLOSE: carry on without
    view = "guide"
    render()
end

local function typed(ch)
    if #setup.addr < 60 then setup.addr = setup.addr .. ch end
    render()
end

---------------------------------------------------------------------------
-- Streams (pad key 4): internet radio and TV links
---------------------------------------------------------------------------

svisible = function()
    ssel = math.max(1, math.min(#presets.streams, ssel))
    if ssel <= stop_ then stop_ = ssel - 1 end
    if ssel > stop_ + ROWS then stop_ = ssel - ROWS end
    stop_ = math.max(0, math.min(stop_, #presets.streams - ROWS))
end

local function smove(d) ssel = ssel + d; svisible(); redraw_soon() end

local function streams_changed()
    write_presets(presets)
    presets_dirty = true
    merge_lineup()
end

-- The keys a stream is on: TV's or radio's
local function off_keys(url)
    for _, l in ipairs({ presets.tv, presets.radio }) do
        for k = #l, 1, -1 do if l[k].url == url then table.remove(l, k) end end
    end
end

-- ADD LINK: the link on the clipboard, named from the station if it says
-- (Icecast's icy-name), TV if it has a picture, radio if not
local function sadd()
    if adding then return end
    adding = true
    render()
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "/bin/sh", "-c", "pbpaste 2>/dev/null || xclip -o -selection clipboard 2>/dev/null" } },
    function(_, res)
        local url = (((res and res.stdout) or ""):match("^%s*(%S+)") or "")
        if not url:match("^%a[%w+.-]*://") then
            adding = false
            say("COPY A STREAM'S LINK FIRST, THEN ADD", 4)
            return
        end
        if url:match("youtube%.com/") or url:match("youtu%.be/") then
            adding = false
            say("THAT'S A YOUTUBE LINK, NOT A STREAM", 4)
            return
        end
        for i, st in ipairs(presets.streams) do
            if st.url == url then adding = false; ssel = i; svisible(); say("ALREADY HERE", 3); return end
        end
        say("CHECKING THE LINK …", 10)
        mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
            args = { "/bin/sh", "-c",
                'ffprobe -v error -rw_timeout 6000000 -show_entries stream=codec_type:format_tags=icy-name ' ..
                '-of json "$1" > /tmp/mpv-tvh-probe.json 2>/dev/null & p=$!; ' ..
                '( sleep 9; kill $p 2>/dev/null ) >/dev/null 2>&1 & k=$!; wait $p; kill $k 2>/dev/null; ' ..
                'cat /tmp/mpv-tvh-probe.json; rm -f /tmp/mpv-tvh-probe.json', "sh", url } },
        function(_, r2)
            adding = false
            local j = utils.parse_json(((r2 and r2.stdout) or ""):match("%b{}") or "")
            local video, name = false, nil
            for _, st in ipairs(j and j.streams or {}) do if st.codec_type == "video" then video = true end end
            name = j and j.format and j.format.tags and (j.format.tags["icy-name"] or j.format.tags["ICY-NAME"])
            if not name or name == "" then name = url:match("^%a[%w+.-]*://([^/:]+)") or url end
            presets.streams[#presets.streams + 1] = { url = url, title = name, radio = not video }
            ssel = #presets.streams
            svisible()
            streams_changed()
            say(j and ("ADDED AS " .. (video and "TV" or "RADIO") .. "  ·  TYPE TO RENAME IT")
                or "COULDN'T CHECK IT: ADDED AS RADIO  ·  TYPE TO RENAME IT", 5)
        end)
    end)
end

local function skind()                     -- knob 1: TV or radio (off the other's keys)
    local st = presets.streams[ssel]
    if not st then return end
    local was_on = slot_of(st.radio ~= false and presets.radio or presets.tv, st.url)
    st.radio = st.radio == false
    off_keys(st.url)
    streams_changed()
    say((st.radio and "RADIO" or "TV") .. (was_on and "  ·  OFF ITS KEY: PUT IT ON ONE IN PRESETS" or ""), 3)
end

local function sremove()                   -- REMOVE (press twice)
    local st = presets.streams[ssel]
    if not st then return end
    if mp.get_time() > remove_confirm then
        remove_confirm = mp.get_time() + 4
        say("REMOVE " .. (st.title or ""):upper() .. "?  PRESS AGAIN", 4)
        mp.add_timeout(4.1, render)
        return
    end
    remove_confirm = 0
    table.remove(presets.streams, ssel)
    off_keys(st.url)
    svisible()
    streams_changed()
    say("REMOVED  " .. (st.title or ""):upper(), 3)
end

local function srename(ch)                 -- typing: the selected stream's name
    local st = presets.streams[ssel]
    if not st then return end
    if ch == nil then st.title = (st.title or ""):sub(1, -2) else st.title = (st.title or "") .. ch end
    for _, l in ipairs({ presets.tv, presets.radio }) do
        for _, e in ipairs(l) do if e.url == st.url then e.title = st.title end end
    end
    streams_changed()
    render()
end

local STACTIONS = { watch = sadd, rec = skind, series = sremove }

local function pnext()                     -- the third button: NEXT: RADIO, DONE, or SETUP
    if wizard == "tv" then
        wizard, filter, psel, ptop = "radio", "RADIO", 1, 0
        render()
    elseif wizard == "radio" then
        wizard = nil
        say("ALL SET  ·  KEY 3 CHANGES THE PRESETS ANY TIME", 4)
        show("guide")                      -- (which applies the presets)
    else
        view = "setup"; setup.addr = TVH_HOST; render()
    end
end
local PACTIONS = { watch = ptoggle, rec = pclear, series = pnext }
local SACTIONS = { watch = sconnect, rec = sfind, series = scancel }

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function build_static()
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
    ev[#ev + 1] = text(D.x + 90, 23, 4, 10, C.silk, "EG-252", { bold = true, spacing = 1.5 })
    ev[#ev + 1] = text(D.x + 142, 23, 4, 7.5, C.silk_dim, RADIO and "RADIO GUIDE" or "PROGRAMME GUIDE", { spacing = 2.5 })
    ev[#ev + 1] = text(D.x + D.w, 23, 6, 7.5, C.silk_dim,
        "1 GUIDE  ·  2 RECORDINGS  ·  3 PRESETS  ·  4 STREAMS  ·  KNOB 1: TIME  ·  KNOB 2: CHANNEL  ·  PRESS " .. (RADIO and "LISTEN" or "WATCH") .. " / REC", { spacing = 1.5 })
    ev[#ev + 1] = shape(rrect_path(D.x - 7, D.y - 7, D.w + 14, D.h + 14, 9), C.bezel)
    ev[#ev + 1] = shape(rrect_path(D.x - 7, D.y - 7, D.w + 14, 3, 2), "#000000", 60)
    ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), C.window)
    return table.concat(ev, "\n")
end

local function hit(id, x, y, w, h, extra)
    local t = extra or {}
    t.id, t.x, t.y, t.w, t.h = id, x, y, w, h
    hits[#hits + 1] = t
end

local function hm(t) return os.date("%H:%M", t) end

local function dur(s)
    local m = math.floor(s / 60 + 0.5)
    if m < 60 then return m .. " MIN" end
    return string.format("%dH%02dM", math.floor(m / 60), m % 60)
end

-- Red marks: recording now (dot), scheduled (ring), all episodes (two rings)
local function mark(ev, e, x, cy, r)
    if not e.dvrState then return 0 end
    if series_of[e.dvrUuid or ""] then
        ev[#ev + 1] = shape(ring_path(x + r, cy, r, 2.2) .. ring_path(x + 2.6 * r, cy, r, 2.2), C.rec)
        return 3.8 * r + 8
    elseif e.dvrState == "recording" then
        ev[#ev + 1] = shape(circle_path(x + r, cy, r + 3), C.rec, 150, 5)
        ev[#ev + 1] = shape(circle_path(x + r, cy, r), C.rec)
        return 2 * r + 9
    elseif e.dvrState == "scheduled" then
        ev[#ev + 1] = shape(ring_path(x + r, cy, r, 2.2), C.rec)
        return 2 * r + 9
    end
    return 0
end

local function size_str(b)
    if b >= 1e9 then return string.format("%.1f GB", b / 1e9) end
    if b >= 1e6 then return string.format("%d MB", math.floor(b / 1e6 + 0.5)) end
    return ""
end

local function wrap(desc, width, lines)
    local per = math.floor(width / 6.8)
    local out, line = {}, ""
    for word in desc:gmatch("%S+") do
        if #line + #word + 1 > per then out[#out + 1] = line; line = word else
            line = line == "" and word or (line .. " " .. word) end
        if #out == lines then break end
    end
    if #out < lines and line ~= "" then out[#out + 1] = line
    elseif #out == lines and lines > 0 then out[lines] = out[lines] .. " …" end
    return out
end

local function draw_recs(ev, FL, now)
    ev[#ev + 1] = text(D.x + 14, D.y + 22, 4, 19, FL[1], "RECORDINGS", { bold = true, spacing = 3 })
    ev[#ev + 1] = text(D.x + D.w - 14, D.y + 22, 6, 19, FL[1], hm(now), { bold = true, spacing = 2 })
    local nsch, nrec = 0, 0
    for _, e in ipairs(recs) do
        if e.state == "recorded" then nrec = nrec + 1 else nsch = nsch + 1 end
    end
    local status = recs_error or ((recs_loading and #recs == 0) and "LOADING"
        or (nsch .. " SCHEDULED  ·  " .. nrec .. " RECORDED"))
    ev[#ev + 1] = text(D.x + D.w - 78, D.y + 23, 6, 10.5, recs_error and C.rec or FL[2], status, { spacing = 2 })
    local lx, ly = D.x + 190, D.y + 22
    ev[#ev + 1] = shape(circle_path(lx + 5, ly, 4.5), C.rec)
    ev[#ev + 1] = text(lx + 14, ly, 4, 9.5, FL[2], "RECORDING", { spacing = 1.5 })
    ev[#ev + 1] = shape(ring_path(lx + 112, ly, 4.5, 2), C.rec)
    ev[#ev + 1] = text(lx + 122, ly, 4, 9.5, FL[2], "SCHEDULED", { spacing = 1.5 })
    ev[#ev + 1] = shape(ring_path(lx + 222, ly, 4.5, 2) .. ring_path(lx + 229, ly, 4.5, 2), C.rec)
    ev[#ev + 1] = text(lx + 239, ly, 4, 9.5, FL[2], "ALL EPISODES", { spacing = 1.5 })

    -- Columns: when, channel, programme, length
    local CW, CC, CT = D.x + 34, D.x + 214, D.x + 384
    local right = D.x + D.w - 20
    ev[#ev + 1] = text(CW, RULER, 1, 11, FL[2], "WHEN", { spacing = 2 })
    ev[#ev + 1] = text(CC, RULER, 1, 11, FL[2], "CHANNEL", { spacing = 2 })
    ev[#ev + 1] = text(CT, RULER, 1, 11, FL[2], "PROGRAMME", { spacing = 2 })
    ev[#ev + 1] = shape(rect_path(D.x + 14, RULER + 6, D.w - 28, 1), FL[3])
    if #recs == 0 and not recs_loading and not recs_error then
        ev[#ev + 1] = text(CW, ROW0 + RH / 2, 4, 15, FL[2], "NOTHING RECORDED OR SCHEDULED")
    end
    for r = 1, ROWS do
        local i = rtop + r
        local e = recs[i]
        if not e then break end
        local y = ROW0 + (r - 1) * RH
        local cur = i == rsel
        if cur then
            ev[#ev + 1] = shape(rrect_path(D.x + 10, y + 4, D.w - 20, RH - 8, 4), FL[1])
            ev[#ev + 1] = shape(rrect_path(D.x + 12.5, y + 6.5, D.w - 25, RH - 13, 3), C.window)
            ev[#ev + 1] = shape(rrect_path(D.x + 12.5, y + 6.5, D.w - 25, RH - 13, 3), FL[3], 40)
        end
        local cy = y + RH / 2
        local col = (cur or e.state ~= "recorded") and FL[1] or FL[2]
        local fake = { dvrState = e.state ~= "recorded" and e.state or nil, dvrUuid = e.autorec and e.uuid }
        if e.autorec then series_of[e.uuid] = series_of[e.uuid] or e.autorec end
        mark(ev, fake, D.x + 18, cy, 4)
        local day = os.date("%Y%m%d", e.start) == os.date("%Y%m%d", now) and "TODAY"
            or os.date("%a %d %b", e.start):upper()
        ev[#ev + 1] = text(CW, cy, 4, 14, col, day .. "  " .. hm(e.start), { spacing = 0.5 })
        ev[#ev + 1] = text(CC, cy, 4, 14, col, e.channel:upper(),
            { spacing = 0.5, clip = { CC, y, CT - CC - 12, RH } })
        local title = e.title .. ((e.subtitle ~= "" and e.subtitle ~= e.title and #e.subtitle < 60)
            and ("  ·  " .. e.subtitle) or "")
        ev[#ev + 1] = text(CT, cy, 4, 16, col, title, { bold = cur, clip = { CT, y, right - 90 - CT, RH } })
        local tail = e.state == "recording" and "REC" or dur(math.max(0, e.stop - e.start))
        ev[#ev + 1] = text(right, cy, 6, 13, e.state == "recording" and C.rec or col, tail, { spacing = 1 })
        hit("rrow", D.x + 10, y, D.w - 20, RH, { i = i })
    end
    if #recs > ROWS then
        local th = ROWS * RH * ROWS / #recs
        local ty = ROW0 + ROWS * RH * rtop / #recs
        ev[#ev + 1] = shape(rrect_path(D.x + D.w - 9, ty, 3.5, th, 2), FL[2])
    end

    -- Details
    ev[#ev + 1] = shape(rrect_path(DET.x, DET.y, DET.w, DET.h, 6), FL[3], 120)
    local e = rec_selected()
    local tw = BUTTONS[1].x - DET.x - 28
    if e then
        ev[#ev + 1] = text(DET.x + 16, DET.y + 22, 4, 22, FL[1], e.title,
            { bold = true, clip = { DET.x, DET.y, tw + 16, 44 } })
        local info = { e.channel:upper(), os.date("%a %d %b", e.start):upper(),
                       hm(e.start) .. " – " .. hm(e.stop) }
        if e.state == "recording" then info[#info + 1] = "RECORDING"
        elseif e.state == "scheduled" then info[#info + 1] = "WILL RECORD"
        else
            if size_str(e.size) ~= "" then info[#info + 1] = size_str(e.size) end
            if e.status ~= "" and not e.status:lower():find("ok") then info[#info + 1] = e.status:upper() end
        end
        if e.autorec then info[#info + 1] = "ALL EPISODES" end
        ev[#ev + 1] = text(DET.x + 16, DET.y + 47, 4, 12, FL[2], table.concat(info, "  ·  "),
            { spacing = 1.5, clip = { DET.x, DET.y, tw + 16, DET.h } })
        local desc = e.desc
        if e.subtitle ~= "" and e.subtitle ~= e.title and not desc:find(e.subtitle, 1, true) then
            desc = desc == "" and e.subtitle or (e.subtitle .. (e.subtitle:match("[%.!?]$") and "  " or ".  ") .. desc)
        end
        for k, l in ipairs(wrap(desc, tw, math.floor((DET.h - 64) / 19))) do
            ev[#ev + 1] = text(DET.x + 16, DET.y + 71 + (k - 1) * 19, 4, 15, FL[2], l,
                { clip = { DET.x, DET.y, tw + 16, DET.h } })
        end
    end

    -- Buttons
    local asking = e and confirm.uuid == e.uuid and mp.get_time() < confirm.until_t
    for _, b in ipairs(BUTTONS) do
        local label, sub, enabled, lit = b.label, b.sub, false, false
        if b.id == "watch" then
            enabled = e ~= nil and e.state ~= "scheduled"
            sub = "ENTER"
        elseif b.id == "rec" then
            enabled = e ~= nil
            if e and e.state == "recording" then label, lit = "STOP REC", true
            elseif e and e.state == "scheduled" then label, lit = "CANCEL REC", true
            else label, sub, lit = asking and "DELETE: SURE?" or "DELETE", "PRESS TWICE", asking end
            if e and e.state ~= "recorded" then sub = "" end
        else
            enabled, lit = e ~= nil and e.autorec ~= nil, e ~= nil and e.autorec ~= nil
            label, sub = lit and "CANCEL ALL" or "ALL EPISODES", "ALT + ENTER"
        end
        local down = pressed.id == b.id and mp.get_time() < pressed.until_t
        local edge = enabled and (lit and C.rec or FL[2]) or FL[3]
        ev[#ev + 1] = shape(rrect_path(b.x, b.y, BW, BH, 5), edge)
        ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 1.5, BW - 3, BH - 3, 4), down and FL[3] or C.window)
        ev[#ev + 1] = text(b.x + BW / 2, b.y + 13, 5, 12.5, enabled and (lit and C.rec or FL[1]) or FL[3], label,
            { bold = true, spacing = 1 })
        ev[#ev + 1] = text(b.x + BW / 2, b.y + 26, 5, 7.5, enabled and FL[2] or FL[3], sub, { spacing = 0.5 })
        if enabled then hit("btn", b.x, b.y, BW, BH, { btn = b.id }) end
    end
end

-- A touch-style button in the details panel (the guide's)
local function button(ev, FL, b, label, sub, enabled, lit)
    local down = pressed.id == b.id and mp.get_time() < pressed.until_t
    ev[#ev + 1] = shape(rrect_path(b.x, b.y, BW, BH, 5), enabled and (lit and C.rec or FL[2]) or FL[3])
    ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 1.5, BW - 3, BH - 3, 4), down and FL[3] or C.window)
    ev[#ev + 1] = text(b.x + BW / 2, b.y + 13, 5, 12.5, enabled and (lit and C.rec or FL[1]) or FL[3], label,
        { bold = true, spacing = 1 })
    ev[#ev + 1] = text(b.x + BW / 2, b.y + 26, 5, 7.5, enabled and FL[2] or FL[3], sub, { spacing = 0.5 })
    if enabled then hit("btn", b.x, b.y, BW, BH, { btn = b.id }) end
end

local function heading(ev, FL, now, title)
    ev[#ev + 1] = text(D.x + 14, D.y + 22, 4, 19, FL[1], title, { bold = true, spacing = 3 })
    ev[#ev + 1] = text(D.x + D.w - 14, D.y + 22, 6, 19, FL[1], hm(now), { bold = true, spacing = 2 })
end

local function details_text(ev, FL, title, info, lines)
    local tw = BUTTONS[1].x - DET.x - 28
    ev[#ev + 1] = shape(rrect_path(DET.x, DET.y, DET.w, DET.h, 6), FL[3], 120)
    if title then
        ev[#ev + 1] = text(DET.x + 16, DET.y + 22, 4, 22, FL[1], title,
            { bold = true, clip = { DET.x, DET.y, tw + 16, 44 } })
    end
    if info then
        ev[#ev + 1] = text(DET.x + 16, DET.y + 47, 4, 12, FL[2], info,
            { spacing = 1.5, clip = { DET.x, DET.y, tw + 16, DET.h } })
    end
    for k, l in ipairs(lines or {}) do
        if DET.y + 71 + (k - 1) * 19 > DET.y + DET.h - 8 then break end
        ev[#ev + 1] = text(DET.x + 16, DET.y + 71 + (k - 1) * 19, 4, 15, FL[2], l,
            { clip = { DET.x, DET.y, tw + 16, DET.h } })
    end
end

-- Presets: the filters, Tvheadend's channels on the left, the eight keys on the right
local function draw_presets(ev, FL, now)
    heading(ev, FL, now, "PRESETS")
    local list, keys = filtered(), slots()
    local status = lineup_error or (lineup_loading and "ASKING TVHEADEND" or
        ((wizard == "tv" and "STEP 1 OF 2: TV  ·  ") or (wizard == "radio" and "STEP 2 OF 2: RADIO  ·  ") or
         ((#list == 1 and "1 CHANNEL" or (#list .. " CHANNELS")) .. "  ·  ")) .. #keys .. " OF 8 KEYS")
    ev[#ev + 1] = text(D.x + D.w - 78, D.y + 23, 6, 10.5, lineup_error and C.rec or FL[2], status, { spacing = 2 })
    -- Filters (knob 1)
    local fx = D.x + 170
    for _, f in ipairs(filters) do
        local on = f == filter
        local w = #f * 8.2 + 22
        if fx + w > D.x + D.w - 260 then break end
        ev[#ev + 1] = shape(rrect_path(fx, D.y + 11, w, 23, 4), on and FL[1] or FL[3])
        ev[#ev + 1] = shape(rrect_path(fx + 1.5, D.y + 12.5, w - 3, 20, 3), on and C.window or C.window)
        ev[#ev + 1] = text(fx + w / 2, D.y + 23, 5, 10.5, on and FL[1] or FL[2], f:upper(), { bold = on, spacing = 1.5 })
        hit("pfilter", fx, D.y + 11, w, 23, { f = f })
        fx = fx + w + 6
    end
    -- Column headings
    local LX, LW = D.x + 10, math.floor(D.w * 0.6)
    local KX = LX + LW + 18
    local KW = D.x + D.w - 10 - KX
    ev[#ev + 1] = text(LX + 34, RULER, 3, 11, FL[2], "CH", { spacing = 2 })
    ev[#ev + 1] = text(LX + 50, RULER, 1, 11, FL[2], "CHANNEL", { spacing = 2 })
    ev[#ev + 1] = text(KX + 4, RULER, 1, 11, FL[2], (filter == "RADIO" and "RADIO" or "TV") .. " KEYS", { spacing = 2 })
    ev[#ev + 1] = shape(rect_path(D.x + 14, RULER + 6, D.w - 28, 1), FL[3])
    ev[#ev + 1] = shape(rect_path(KX - 9, RULER + 10, 1, ROWS * RH - 4), FL[3])
    if TVH_HOST == "" and #list == 0 then
        ev[#ev + 1] = text(LX + 10, ROW0 + RH / 2, 4, 15, FL[2], "SET UP TVHEADEND FIRST (SETUP), OR ADD STREAMS (KEY 4)")
    elseif not lineup_loading and #list == 0 and lineup then
        ev[#ev + 1] = text(LX + 10, ROW0 + RH / 2, 4, 15, FL[2], "NOTHING OF THIS KIND ON TVHEADEND")
    end
    pvisible()
    for r = 1, ROWS do
        local i = ptop + r
        local c = list[i]
        if not c then break end
        local y = ROW0 + (r - 1) * RH
        local cur = i == psel
        if cur then
            ev[#ev + 1] = shape(rrect_path(LX, y + 4, LW, RH - 8, 4), FL[1])
            ev[#ev + 1] = shape(rrect_path(LX + 2.5, y + 6.5, LW - 5, RH - 13, 3), C.window)
            ev[#ev + 1] = shape(rrect_path(LX + 2.5, y + 6.5, LW - 5, RH - 13, 3), FL[3], 40)
        end
        local k = slot_of(c.radio and presets.radio or presets.tv, c.id)
        local cy = y + RH / 2
        ev[#ev + 1] = text(LX + 34, cy, 6, 13, cur and FL[1] or FL[2], c.number > 0 and tostring(c.number) or "", { spacing = 1 })
        ev[#ev + 1] = text(LX + 50, cy, 4, 16.5, (cur or k) and FL[1] or FL[2], c.title,
            { bold = cur, clip = { LX + 50, y, LW - 50 - 80, RH } })
        ev[#ev + 1] = text(LX + LW - 50, cy, 6, 10, FL[2], c.kind, { spacing = 1.5 })
        if k then
            ev[#ev + 1] = shape(rrect_path(LX + LW - 40, cy - 11, 30, 22, 4), FL[1])
            ev[#ev + 1] = text(LX + LW - 25, cy, 5, 13, C.window, tostring(k), { bold = true })
        end
        hit("prow", LX, y, LW, RH, { i = i })
    end
    if #list > ROWS then
        local th = ROWS * RH * ROWS / #list
        local ty = ROW0 + ROWS * RH * ptop / #list
        ev[#ev + 1] = shape(rrect_path(LX + LW + 4, ty, 3.5, th, 2), FL[2])
    end
    -- The eight keys
    local kp = math.min(RH, (ROWS * RH) / 8)
    for k = 1, 8 do
        local e = keys[k]
        local y = ROW0 + (k - 1) * kp
        local cy = y + kp / 2
        ev[#ev + 1] = shape(rrect_path(KX, cy - 11, 26, 22, 4), e and FL[1] or FL[3])
        ev[#ev + 1] = text(KX + 13, cy, 5, 13, e and C.window or FL[2], tostring(k), { bold = true })
        ev[#ev + 1] = text(KX + 38, cy, 4, 15, e and FL[1] or FL[3], e and e.title or "—",
            { clip = { KX + 38, y, KW - 40, kp } })
    end
    -- Details and buttons
    local c = list[psel]
    local k = c and slot_of(c.radio and presets.radio or presets.tv, c.id)
    details_text(ev, FL, c and c.title or "PRESETS",
        c and table.concat({ c.number > 0 and ("CHANNEL " .. c.number) or "NO NUMBER", c.kind,
            k and ("ON KEY " .. k) or "NOT ON A KEY" }, "  ·  ") or nil,
        wizard == "tv" and { "These are the TV's keys. Press a knob to put a channel on the next free",
                             "key, or take it off. Then NEXT: RADIO for the radio's." }
        or wizard == "radio" and { "These are the radio's keys. Press a knob to put a station on the next",
                                   "free key, or take it off. Then DONE." }
        or { "Press a knob to put this one on the next free key, or take it off.",
             "Knob 1 changes the filter; RADIO's are the radio's keys, the rest the TV's." })
    button(ev, FL, BUTTONS[1], k and "TAKE OFF" or "ADD", "ENTER", c ~= nil, false)
    local asking = mp.get_time() < clear_confirm
    button(ev, FL, BUTTONS[2], asking and "CLEAR: SURE?" or "CLEAR KEYS", "PRESS TWICE", #keys > 0, asking)
    if wizard == "tv" then button(ev, FL, BUTTONS[3], "NEXT: RADIO", "ALT + ENTER", true, false)
    elseif wizard == "radio" then button(ev, FL, BUTTONS[3], "DONE", "ALT + ENTER", true, false)
    else button(ev, FL, BUTTONS[3], "SETUP", "TVHEADEND'S ADDRESS", true, false) end
end

-- Streams: the links kept, their names and kinds
local function draw_streams(ev, FL, now)
    heading(ev, FL, now, "STREAMS")
    local list = presets.streams
    ev[#ev + 1] = text(D.x + D.w - 78, D.y + 23, 6, 10.5, FL[2],
        adding and "CHECKING THE LINK" or (#list == 1 and "1 STREAM" or (#list .. " STREAMS")), { spacing = 2 })
    local NX, TX, UX = D.x + 24, D.x + 330, D.x + 420
    ev[#ev + 1] = text(NX, RULER, 1, 11, FL[2], "NAME", { spacing = 2 })
    ev[#ev + 1] = text(TX, RULER, 1, 11, FL[2], "FOR", { spacing = 2 })
    ev[#ev + 1] = text(UX, RULER, 1, 11, FL[2], "LINK", { spacing = 2 })
    ev[#ev + 1] = shape(rect_path(D.x + 14, RULER + 6, D.w - 28, 1), FL[3])
    if #list == 0 then
        ev[#ev + 1] = text(NX, ROW0 + RH / 2, 4, 15, FL[2], "Copy an internet radio or TV stream's link, then press a knob to add it.")
    end
    svisible()
    for r = 1, ROWS do
        local i = stop_ + r
        local st = list[i]
        if not st then break end
        local y = ROW0 + (r - 1) * RH
        local cur = i == ssel
        if cur then
            ev[#ev + 1] = shape(rrect_path(D.x + 10, y + 4, D.w - 20, RH - 8, 4), FL[1])
            ev[#ev + 1] = shape(rrect_path(D.x + 12.5, y + 6.5, D.w - 25, RH - 13, 3), C.window)
            ev[#ev + 1] = shape(rrect_path(D.x + 12.5, y + 6.5, D.w - 25, RH - 13, 3), FL[3], 40)
        end
        local cy = y + RH / 2
        ev[#ev + 1] = text(NX, cy, 4, 16.5, cur and FL[1] or FL[2], (st.title or "") .. (cur and "▏" or ""),
            { bold = cur, clip = { NX, y, TX - NX - 12, RH } })
        ev[#ev + 1] = text(TX, cy, 4, 11, cur and FL[1] or FL[2], st.radio == false and "TV" or "RADIO", { spacing = 1.5 })
        ev[#ev + 1] = text(UX, cy, 4, 12, FL[2], st.url, { clip = { UX, y, D.x + D.w - 24 - UX, RH } })
        hit("srow", D.x + 10, y, D.w - 20, RH, { i = i })
    end
    if #list > ROWS then
        local th = ROWS * RH * ROWS / #list
        local ty = ROW0 + ROWS * RH * stop_ / #list
        ev[#ev + 1] = shape(rrect_path(D.x + D.w - 9, ty, 3.5, th, 2), FL[2])
    end
    local st = list[ssel]
    local keys = st and slot_of(st.radio == false and presets.tv or presets.radio, st.url)
    details_text(ev, FL, st and st.title or "STREAMS",
        st and ((st.radio == false and "TV" or "RADIO") .. "  ·  " .. (keys and ("ON KEY " .. keys) or "NOT ON A KEY"))
            or "INTERNET RADIO AND TV",
        { "Copy a link, then press a knob to add it. Type to rename the one selected;",
          "knob 1 makes it TV or radio. Then key 3 (presets) to put it on a key." })
    button(ev, FL, BUTTONS[1], adding and "CHECKING …" or "ADD LINK", "ENTER · FROM THE CLIPBOARD", not adding, false)
    button(ev, FL, BUTTONS[2], st and (st.radio == false and "MAKE IT RADIO" or "MAKE IT TV") or "TV / RADIO",
        "KNOB 1", st ~= nil, false)
    local asking = mp.get_time() < remove_confirm
    button(ev, FL, BUTTONS[3], asking and "REMOVE: SURE?" or "REMOVE", "PRESS TWICE", st ~= nil, asking)
end

-- SETUP: Tvheadend's address
local function draw_setup(ev, FL, now)
    heading(ev, FL, now, "SETUP")
    ev[#ev + 1] = text(D.x + D.w - 78, D.y + 23, 6, 10.5, FL[2],
        TVH_HOST ~= "" and ("NOW  " .. TVH_HOST:upper()) or "NOT SET UP YET", { spacing = 2 })
    local y0 = ROW0 + 10
    ev[#ev + 1] = text(D.x + 30, y0, 4, 16.5, FL[1], "Where's your Tvheadend server?")
    ev[#ev + 1] = text(D.x + 30, y0 + 30, 4, 14, FL[2],
        "Type its address (a name or IP address, and :9981 if it isn't the usual port),")
    ev[#ev + 1] = text(D.x + 30, y0 + 52, 4, 14, FL[2], "or FIND to look for it on your network. Then CONNECT."
        .. (DEMO and TVH_HOST == "" and "  Or DEMO to try it first." or ""))
    local bx, by, bw, bh = D.x + 30, y0 + 84, D.w - 60, 44
    ev[#ev + 1] = shape(rrect_path(bx, by, bw, bh, 6), FL[1])
    ev[#ev + 1] = shape(rrect_path(bx + 2, by + 2, bw - 4, bh - 4, 5), C.window)
    local shown = setup.addr ~= "" and setup.addr or ""
    ev[#ev + 1] = text(bx + 18, by + bh / 2, 4, 20, FL[1], shown .. "▏", { clip = { bx, by, bw - 20, bh } })
    if setup.addr == "" then
        ev[#ev + 1] = text(bx + 30, by + bh / 2, 4, 16, FL[3], "e.g.  tvheadend.local  or  192.168.0.10")
    end
    if setup.checking then
        ev[#ev + 1] = text(bx, by + bh + 26, 4, 13, FL[2], "ASKING TVHEADEND …", { spacing = 2 })
    elseif setup.finding then
        ev[#ev + 1] = text(bx, by + bh + 26, 4, 13, FL[2], "LOOKING ON THE NETWORK …", { spacing = 2 })
    end
    details_text(ev, FL, "TVHEADEND", "NO LOGIN: SET TVHEADEND TO ALLOW YOUR NETWORK",
        { "Once it's connected, pick up to eight TV channels and eight radio stations",
          "for the pad's keys, from everything on the server (key 3: presets)." })
    button(ev, FL, BUTTONS[1], "CONNECT", "ENTER", setup.addr ~= "" and not setup.checking, false)
    button(ev, FL, BUTTONS[2], "FIND", "ON THE NETWORK", not setup.finding, false)
    if TVH_HOST ~= "" then button(ev, FL, BUTTONS[3], "CANCEL", "ESC", true, false)
    elseif DEMO then button(ev, FL, BUTTONS[3], "DEMO", "TEST CARDS · NET RADIO", true, false)
    else button(ev, FL, BUTTONS[3], "CLOSE", "ESC", true, false) end
end

-- The guide itself: channels against time, and the selected programme
local function draw_guide(ev, FL, now)
    -- Heading: the day, and the time
    local today = os.date("%a %d %b", now):upper()
    local day = os.date("%a %d %b", view0):upper()
    ev[#ev + 1] = text(D.x + 14, D.y + 22, 4, 19, FL[1],
        day == today and "TODAY" or day, { bold = true, spacing = 3 })
    ev[#ev + 1] = text(D.x + D.w - 14, D.y + 22, 6, 19, FL[1], hm(now), { bold = true, spacing = 2 })
    local nrec = 0
    for _, c in ipairs(channels) do
        for _, e in ipairs(c.events) do if e.dvrState == "scheduled" then nrec = nrec + 1 end end
    end
    local status = load_error or (loading and "LOADING THE GUIDE" or (nrec > 0 and (nrec .. " SCHEDULED") or ""))
    ev[#ev + 1] = text(D.x + D.w - 78, D.y + 23, 6, 10.5, load_error and C.rec or FL[2], status, { spacing = 2 })
    -- Key to the marks
    local lx, ly = D.x + 190, D.y + 22
    ev[#ev + 1] = shape(circle_path(lx + 5, ly, 4.5), C.rec)
    ev[#ev + 1] = text(lx + 14, ly, 4, 9.5, FL[2], "RECORDING", { spacing = 1.5 })
    ev[#ev + 1] = shape(ring_path(lx + 112, ly, 4.5, 2), C.rec)
    ev[#ev + 1] = text(lx + 122, ly, 4, 9.5, FL[2], "SCHEDULED", { spacing = 1.5 })
    ev[#ev + 1] = shape(ring_path(lx + 222, ly, 4.5, 2) .. ring_path(lx + 229, ly, 4.5, 2), C.rec)
    ev[#ev + 1] = text(lx + 239, ly, 4, 9.5, FL[2], "ALL EPISODES", { spacing = 1.5 })

    -- Time ruler, and lines every half hour
    local px = GWID / SPAN
    local lines = {}
    for k = 0, SPAN / 1800 - 1 do
        local t = view0 + k * 1800
        local x = GX + k * 1800 * px
        lines[#lines + 1] = rect_path(x, RULER + 6, 1, ROWS * RH + 8)
        ev[#ev + 1] = text(x + 5, RULER, 1, 13.5, FL[2], hm(t), { spacing = 1 })
        if os.date("%H%M", t) == "0000" then
            ev[#ev + 1] = text(x + 50, RULER, 1, 10, FL[2], os.date("%a", t):upper(), { spacing = 2 })
        end
    end
    ev[#ev + 1] = shape(table.concat(lines), FL[3])

    -- Channel rows
    for r = 1, ROWS do
        local i = top + r
        local c = channels[i]
        if not c then break end
        local y = ROW0 + (r - 1) * RH
        local cur = i == sel.ch
        ev[#ev + 1] = text(D.x + 16, y + RH / 2, 4, 13, cur and FL[1] or FL[2], tostring(i), { spacing = 1 })
        ev[#ev + 1] = text(D.x + 38, y + RH / 2, 4, 16.5, cur and FL[1] or FL[2], (c.title or ""):upper(),
            { bold = cur, spacing = 0.5, clip = { D.x + 38, y, CHW - 44, RH } })
        if i == playing then                              -- the channel the TV's on
            ev[#ev + 1] = shape(rect_path(D.x + 6, y + 11, 3.5, RH - 22), FL[1])
        end
        hit("row", GX, y, GWID, RH, { ch = i })
        if not c.uuid then
            ev[#ev + 1] = text(GX + 12, y + RH / 2, 4, 14, FL[2], "NOT FROM TVHEADEND  ·  NO GUIDE")
        elseif #c.events == 0 and not loading then
            ev[#ev + 1] = text(GX + 12, y + RH / 2, 4, 14, FL[2], "NO PROGRAMME DATA")
        end
        local selev = cur and selected()
        for _, e in ipairs(c.events) do
            if e.start >= view0 + SPAN then break end
            if e.stop > view0 then
                local a, b = math.max(e.start, view0), math.min(e.stop, view0 + SPAN)
                local x, bw = GX + (a - view0) * px + 2, (b - a) * px - 4
                if bw > 2 then
                    local isnow = e.start <= now and e.stop > now
                    local issel = e == selev
                    ev[#ev + 1] = shape(rrect_path(x, y + 4, bw, RH - 8, 4), issel and FL[1] or FL[3],
                        issel and 0 or (isnow and 40 or 120))
                    if issel then
                        ev[#ev + 1] = shape(rrect_path(x + 2.5, y + 6.5, bw - 5, RH - 13, 3), C.window)
                        ev[#ev + 1] = shape(rrect_path(x + 2.5, y + 6.5, bw - 5, RH - 13, 3), FL[3], 40)
                    end
                    local tx = x + 10
                    if bw > 40 then tx = tx + mark(ev, e, tx, y + RH / 2, 5) end
                    local title = (e.start < view0 and "‹ " or "") .. (e.title or "")
                    if bw < 36 then title = "" end            -- a sliver: no room for a name
                    ev[#ev + 1] = text(tx, y + RH / 2, 4, 17, (issel or isnow) and FL[1] or FL[2], title,
                        { bold = issel, clip = { x + 4, y, math.max(0, bw - 12), RH } })
                    hit("ev", x, y + 4, bw, RH - 8, { ch = i, t = math.max(e.start, now) })
                end
            end
        end
    end
    if #channels > ROWS then                              -- more channels: a scroll bar
        local th = ROWS * RH * ROWS / #channels
        local ty = ROW0 + ROWS * RH * top / #channels
        ev[#ev + 1] = shape(rrect_path(D.x + D.w - 9, ty, 3.5, th, 2), FL[2])
    end
    -- Now
    if now >= view0 and now < view0 + SPAN then
        local nx = GX + (now - view0) * px
        ev[#ev + 1] = shape(rect_path(nx - 1, RULER + 6, 2, ROWS * RH + 8), FL[1], 60)
        ev[#ev + 1] = shape(string.format("m %s %s l %s %s l %s %s ", f1(X(nx - 7)), f1(Y(RULER + 4)),
            f1(X(nx + 7)), f1(Y(RULER + 4)), f1(X(nx)), f1(Y(RULER + 13))), FL[1])
    end

    -- Details of the selected programme
    ev[#ev + 1] = shape(rrect_path(DET.x, DET.y, DET.w, DET.h, 6), FL[3], 120)
    local e, c = selected(), channels[sel.ch]
    local tw = BUTTONS[1].x - DET.x - 28
    if e then
        local tx = DET.x + 16
        tx = tx + mark(ev, e, tx, DET.y + 22, 6)
        ev[#ev + 1] = text(tx, DET.y + 22, 4, 22, FL[1], e.title or "",
            { bold = true, clip = { DET.x, DET.y, tw + 16, 44 } })
        local when
        if on_now(e) then when = "ON NOW, " .. dur(e.stop - now) .. " LEFT"
        elseif os.date("%Y%m%d", e.start) == os.date("%Y%m%d", now) then when = "TODAY"
        else when = os.date("%a %d %b", e.start):upper() end
        local info = { (c and c.title or ""):upper(), hm(e.start) .. " – " .. hm(e.stop), when }
        if e.episodeOnscreen and e.episodeOnscreen ~= "" then info[#info + 1] = e.episodeOnscreen:upper() end
        if e.dvrState == "recording" then info[#info + 1] = "RECORDING"
        elseif e.dvrState == "scheduled" then info[#info + 1] = "WILL RECORD" end
        if series_of[e.dvrUuid or ""] then info[#info + 1] = "ALL EPISODES" end
        ev[#ev + 1] = text(DET.x + 16, DET.y + 47, 4, 12, FL[2], table.concat(info, "  ·  "), { spacing = 1.5, clip = { DET.x, DET.y, tw + 16, DET.h } })
        -- Description, wrapped to the lines there's room for. Freeview puts
        -- a short one in the subtitle (the episode's title elsewhere)
        local desc = e.description or ""
        if desc == "" then desc = e.summary or "" end
        local sub = e.subtitle or ""
        if sub ~= "" and sub ~= e.title and not desc:find(sub, 1, true) then
            desc = desc == "" and sub or (sub .. (sub:match("[%.!?]$") and "  " or ".  ") .. desc)
        end
        local LINES = math.floor((DET.h - 64) / 19)
        local per = math.floor(tw / 6.8)
        local out, line = {}, ""
        for word in desc:gmatch("%S+") do
            if #line + #word + 1 > per then out[#out + 1] = line; line = word else
                line = line == "" and word or (line .. " " .. word) end
            if #out == LINES then break end
        end
        if #out < LINES and line ~= "" then out[#out + 1] = line
        elseif #out == LINES then out[LINES] = out[LINES] .. " …" end
        for k, l in ipairs(out) do
            ev[#ev + 1] = text(DET.x + 16, DET.y + 71 + (k - 1) * 19, 4, 15, FL[2], l,
                { clip = { DET.x, DET.y, tw + 16, DET.h } })
        end
    elseif c then
        ev[#ev + 1] = text(DET.x + 16, DET.y + 22, 4, 20, FL[1], (c.title or ""):upper(), { bold = true })
        ev[#ev + 1] = text(DET.x + 16, DET.y + 47, 4, 11.5, FL[2],
            c.uuid and (loading and "LOADING" or "NO PROGRAMME DATA")
                or "NOT FROM TVHEADEND, SO NO GUIDE: SET IT UP AT TVHEADEND.ORG",
            { spacing = 2 })
    end

    -- Buttons (in the display, like a touch screen)
    for _, b in ipairs(BUTTONS) do
        local lit = (b.id == "rec" and e and (e.dvrState == "scheduled" or e.dvrState == "recording"))
            or (b.id == "series" and e and series_of[e.dvrUuid or ""] ~= nil)
        local enabled = (b.id == "watch" and c ~= nil) or (b.id ~= "watch" and e ~= nil)
        local down = pressed.id == b.id and mp.get_time() < pressed.until_t
        local edge = enabled and (lit and C.rec or FL[2]) or FL[3]
        ev[#ev + 1] = shape(rrect_path(b.x, b.y, BW, BH, 5), edge)
        ev[#ev + 1] = shape(rrect_path(b.x + 1.5, b.y + 1.5, BW - 3, BH - 3, 4), down and FL[3] or C.window)
        local label = b.label
        if b.id == "rec" and lit then label = (e.dvrState == "recording") and "STOP REC" or "CANCEL REC" end
        if b.id == "series" and lit then label = "CANCEL ALL" end
        ev[#ev + 1] = text(b.x + BW / 2, b.y + 13, 5, 12.5, enabled and (lit and C.rec or FL[1]) or FL[3], label,
            { bold = true, spacing = 1 })
        ev[#ev + 1] = text(b.x + BW / 2, b.y + 26, 5, 7.5, enabled and FL[2] or FL[3], b.sub, { spacing = 0.5 })
        if enabled then hit("btn", b.x, b.y, BW, BH, { btn = b.id }) end
    end
end

render = function()
    local w, h = osd_w, osd_h
    if not w or w == 0 or h == 0 then return end
    if w ~= static.w or h ~= static.h then
        overlay.res_x, overlay.res_y = w, h
        backdrop.res_x, backdrop.res_y = w, h
        GH = math.max(400, math.min(1600, GW * h / w))      -- the window's shape
        layout()
        S = math.min(w / GW, h / GH)
        OX, OY = (w - GW * S) / 2, (h - GH * S) / 2
        backdrop.data = build_static()
        backdrop:update()
        static.w, static.h = w, h
    end
    local FL = DISPLAYS[theme]
    local ev = {}
    hits = {}
    local now = os.time()
    if view0 < half_hour(now) then view0 = half_hour(now) end

    if view == "recs" then draw_recs(ev, FL, now)
    elseif view == "presets" then draw_presets(ev, FL, now)
    elseif view == "streams" then draw_streams(ev, FL, now)
    elseif view == "setup" then draw_setup(ev, FL, now) else
    draw_guide(ev, FL, now)
    end                                                   -- (the guide)
    if notice.text and mp.get_time() < notice.until_t then   -- over the details' heading
        local tw = BUTTONS[1].x - DET.x - 28
        ev[#ev + 1] = shape(rrect_path(DET.x + 6, DET.y + 4, tw + 14, 36, 4), C.window)
        ev[#ev + 1] = text(DET.x + 16, DET.y + 22, 4, 17, FL[1], notice.text,
            { bold = true, spacing = 1.5, clip = { DET.x, DET.y, tw + 16, 50 } })
    end

    -- Dimmed while another window is active
    if mp.get_property_bool("focused", true) == false then
        ev[#ev + 1] = shape(rrect_path(D.x, D.y, D.w, D.h, 4), "#000000", 178)
    end
    overlay.data = table.concat(ev, "\n")
    overlay:update()
end

---------------------------------------------------------------------------
-- Mouse and keys
---------------------------------------------------------------------------

local function grid_mouse()
    local m = mp.get_property_native("mouse-pos") or {}
    return ((m.x or -1) - OX) / S, ((m.y or -1) - OY) / S
end

local function hit_at(x, y)
    local found
    for _, t in ipairs(hits) do
        if x >= t.x and x <= t.x + t.w and y >= t.y and y <= t.y + t.h then
            if t.id ~= "row" then return t end
            found = found or t
        end
    end
    return found
end

local function click_select(t)
    if t.id == "ev" then sel.ch, sel.t = t.ch, t.t
    elseif t.id == "row" then sel.ch = t.ch; local e = selected(); if e then sel.t = math.max(sel.t, e.start) end end
    keep_visible()
    render()
end

mp.add_forced_key_binding("MBTN_LEFT", "guide-click", function(ev)
    if ev.event ~= "down" then return end
    local t = hit_at(grid_mouse())
    if not t then pcall(mp.commandv, "begin-vo-dragging"); return end
    if t.id == "btn" then
        pressed.id, pressed.until_t = t.btn, mp.get_time() + 0.15
        mp.add_timeout(0.16, render)
        local acts = ({ recs = RACTIONS, presets = PACTIONS, streams = STACTIONS, setup = SACTIONS })[view] or ACTIONS
        acts[t.btn]()
        render()
    elseif t.id == "pfilter" then
        filter, psel, ptop = t.f, 1, 0
        render()
    elseif t.id == "prow" then
        psel = t.i
        pvisible()
        render()
    elseif t.id == "srow" then
        ssel = t.i
        svisible()
        render()
    elseif t.id == "rrow" then
        rsel = t.i
        recs_visible()
        render()
    else
        click_select(t)
    end
end, { complex = true })

mp.commandv("keybind", "MBTN_LEFT_DBL", "script-message guide-double-click")
mp.register_script_message("guide-double-click", function()
    local t = hit_at(grid_mouse())
    if t and t.id == "rrow" then rsel = t.i; renter()
    elseif t and t.id == "prow" then psel = t.i; ptoggle()
    elseif t and (t.id == "ev" or t.id == "row") then click_select(t); enter() end
end)

-- Each key does what it does in the view showing: the guide, the
-- recordings, the presets, SETUP
local function per(t) return function() local f = t[view]; if f then f() end end end
local up = per({ guide = function() across(-1) end, recs = function() rmove(-1) end, presets = function() pmove(-1) end,
                 streams = function() smove(-1) end })
local down = per({ guide = function() across(1) end, recs = function() rmove(1) end, presets = function() pmove(1) end,
                   streams = function() smove(1) end })

mp.add_forced_key_binding("WHEEL_UP", "guide-wheel-up", up)
mp.add_forced_key_binding("WHEEL_DOWN", "guide-wheel-down", down)

local function key(name, fn) mp.add_forced_key_binding(name, "guide-" .. name, fn, { repeatable = true }) end
key("LEFT", per({ guide = function() along(-1) end, presets = function() pfilter(-1) end, streams = skind }))
key("RIGHT", per({ guide = function() along(1) end, presets = function() pfilter(1) end, streams = skind }))
key("UP", up)                                         -- up and down the channels (knob 2)
key("DOWN", down)
key("Alt+UP", up)                                     -- with Alt: the same
key("Alt+DOWN", down)
local enter_all = per({ guide = enter, recs = renter, presets = ptoggle, streams = sadd, setup = sconnect })
key("ENTER", enter_all)
key("KP_ENTER", enter_all)
key("Alt+ENTER", per({ guide = series_toggle, recs = rseries,
                       presets = function() if wizard then pnext() end end }))   -- NEXT: RADIO, DONE
key("PGUP", per({ guide = function() to_time(sel.t - 86400) end, recs = function() rmove(-ROWS) end,
                 presets = function() pmove(-ROWS) end }))
key("PGDWN", per({ guide = function() to_time(sel.t + 86400) end, recs = function() rmove(ROWS) end,
                  presets = function() pmove(ROWS) end }))
key("HOME", per({ guide = function() to_time(os.time()) end, recs = function() rmove(-#recs) end,
                 presets = function() pmove(-100000) end }))
key("ESC", per({ guide = function() to_time(os.time()) end, recs = function() rmove(-#recs) end,
                presets = function() show("guide") end, streams = function() show("guide") end, setup = scancel }))
key("BS", function()
    if view == "setup" then setup.addr = setup.addr:sub(1, -2); render()
    elseif view == "streams" then srename(nil) end
end)
key("F13", function() show("guide") end)              -- pad key 1: the guide
key("F14", function() show("recs") end)               -- pad key 2: the recordings
key("F15", function() show("presets") end)            -- pad key 3: the presets
key("F16", function() show("streams") end)            -- pad key 4: the streams
-- Typing (SETUP's address, a stream's name); r and w record and watch elsewhere
local function typing(name, ch)
    local other = ({ r = function() if view == "guide" then rec_toggle() elseif view == "recs" then rrec() end end,
                     w = function() if view == "guide" then watch() elseif view == "recs" then rwatch() end end })[name]
    key(name, function()
        if view == "setup" then if ch:match("[%w.:_-]") then typed(ch:lower()) end
        elseif view == "streams" then srename(ch)
        elseif other then other() end
    end)
end
for ch in ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_'&!()/+,?"):gmatch(".") do
    typing(ch, ch)
end
typing("SPACE", " ")
mp.register_script_message("guide-show", function(v) show(v or "guide") end)


---------------------------------------------------------------------------
-- Follow the TV: what's on, and close when it quits
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
            local pos = s.stopped and (s.stopped_index or 0) or (s["playlist-pos"] or -1) + 1
            if pos > 0 and pos ~= playing then playing = pos; render() end
            last_t = s.t
        end
    end
    if last_t and os.time() - last_t > 6 then mp.command("quit") end   -- player gone
end)

mp.add_periodic_timer(1, function()
    local f = io.open(ALIVE, "w")
    if f then f:write(os.time(), "\n"); f:close() end
    read_theme()
    render()                                            -- the clock, the now line
end)

mp.add_periodic_timer(300, fetch_events)               -- the guide changes now and then
mp.add_periodic_timer(60, function()
    fetch_upcoming()
    if view == "recs" then fetch_recs() end
end)

mp.observe_property("focused", "native", function() render() end)
mp.observe_property("osd-dimensions", "native", function(_, d)
    if d then osd_w, osd_h = d.w or 0, d.h or 0 end
    render()
end)
mp.commandv("script-message-to", "osc", "osc-visibility", "never", "no-osd")
read_theme()
view0 = half_hour(os.time())
sel.t = os.time()
if TVH_HOST == "" then view, setup.first = "setup", true end        -- the first time: where's Tvheadend?
local first_view = mp.get_opt("guide-view")
if first_view and first_view ~= "" and TVH_HOST ~= "" then view = first_view end
fetch_channels(function()
    sel.ch = math.max(1, playing)
    keep_visible()
    fetch_events()
    -- Nothing on the keys yet (the radio, say, after only the TV's were
    -- picked): straight to the presets, on this player's kind
    if #channels == 0 and TVH_HOST ~= "" and view == "guide" then
        filter, psel, ptop = RADIO and "RADIO" or "ALL", 1, 0
        show("presets")
    end
end)

-- Closing (CLOSE, the GUIDE key, the player gone): tell the faceplate at once, so
-- its GUIDE light goes out and the next press opens it again
mp.register_event("shutdown", function()
    os.remove(ALIVE)
    if presets_dirty then                                -- closed on the presets: still apply them
        mp.command_native({ name = "subprocess", playback_only = false, detach = true,
            args = { "fish", "-c", "__tvh tv --reload; __tvh radio --reload" } })
    end
end)
