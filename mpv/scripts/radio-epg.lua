-- radio-epg.lua
-- Permanent station / now / next display for the radio player.
-- Tvheadend stations show EPG now/next; internet streams show the current track.

local mp = require 'mp'
local utils = require 'mp.utils'

-- Only run in the radio player (identified by its control socket)
if not (mp.get_property("input-ipc-server") or ""):find("mpv%-radio") then return end

-- Tvheadend host, passed in by __tvh.fish (--script-opts-append=tvh-host=...)
local TVH_HOST = mp.get_opt("tvh-host")
if TVH_HOST == "" then TVH_HOST = nil end
local REFRESH = 30                 -- seconds between EPG refreshes

-- ASS colours are &HBBGGRR&
local RED     = "&H4040B0&"        -- #B04040, matches date / calendar widgets
local RED_DIM = "&H2C2C7A&"        -- #7A2C2C, matches world clock digits

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x, overlay.res_y = 1920, 1080   -- layout coordinates, scaled to the window

local entries = nil

local function esc(s)
    return ((s or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"))
end

local function fmt_time(unix)
    return unix and os.date("%H:%M", unix) or "--:--"
end

local function fmt_duration(seconds)
    if not seconds or seconds < 0 then return "" end
    local mins = math.floor(seconds / 60)
    if mins < 60 then return string.format("%dm", mins) end
    local h, m = math.floor(mins / 60), mins % 60
    return m == 0 and string.format("%dh", h) or string.format("%dh %dm", h, m)
end

-- Station name from the playlist entry (#EXTINF title), not media-title,
-- which internet streams overwrite with the current song
local function station_name()
    local pos = mp.get_property_number("playlist-pos", -1)
    local t = pos >= 0 and mp.get_property("playlist/" .. pos .. "/title") or nil
    return t or mp.get_property("media-title", "")
end

local function render()
    local now = os.time()
    local lines = {}

    -- Clock, top right
    table.insert(lines, string.format("{\\an9\\pos(1880,40)\\fs48\\c%s}%s",
        RED_DIM, os.date("%H:%M", now)))

    -- Station name, large, centred
    table.insert(lines, string.format("{\\an5\\pos(960,420)\\fs150\\b1\\c%s}%s",
        RED, esc(station_name())))

    if entries and entries[1] then
        -- Tvheadend station: programme now
        local e = entries[1]
        table.insert(lines, string.format("{\\an5\\pos(960,620)\\fs64\\c%s}%s",
            RED, esc(e.title or "(untitled)")))
        if e.stop and e.stop > now then
            table.insert(lines, string.format("{\\an5\\pos(960,700)\\fs40\\c%s}%s left",
                RED_DIM, fmt_duration(e.stop - now)))
        end
    else
        -- Internet stream: current track from the stream itself
        local icy = mp.get_property("metadata/by-key/icy-title", "")
        if icy ~= "" then
            table.insert(lines, string.format("{\\an5\\pos(960,620)\\fs64\\c%s}%s",
                RED, esc(icy)))
        end
    end

    -- Tvheadend station: programme next
    if entries and entries[2] then
        local e = entries[2]
        table.insert(lines, string.format("{\\an5\\pos(960,840)\\fs48\\c%s}Next: %s  ·  from %s",
            RED_DIM, esc(e.title or "(untitled)"), fmt_time(e.start)))
    end

    overlay.data = table.concat(lines, "\n")
    overlay:update()
end

local function fetch()
    local uuid = mp.get_property("path", ""):match("/stream/channel/(%w+)")
    if not uuid or not TVH_HOST then entries = nil; render(); return end   -- internet stream: no EPG

    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {"curl", "-sS", "--max-time", "3",
            string.format("http://%s/api/epg/events/grid?limit=2&channel=%s", TVH_HOST, uuid)},
    }, function(success, result)
        if success and result and result.status == 0 then
            local parsed = utils.parse_json(result.stdout or "")
            entries = parsed and parsed.entries or nil
        end
        render()
    end)
end

-- Station change: clear old programme info, show the new name immediately, then fetch
mp.register_event("file-loaded", function()
    entries = nil
    render()
    fetch()
end)

mp.observe_property("media-title", "string", render)
mp.observe_property("metadata/by-key/icy-title", "string", render)
mp.add_periodic_timer(REFRESH, fetch)
mp.add_periodic_timer(10, render)   -- keeps the clock and "time left" current
