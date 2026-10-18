-- tv-epg.lua
-- Shows now/next EPG overlay for Tvheadend channels.
-- Triggered by mouse movement (with throttle) or by pressing 'g'.

local mp = require 'mp'
local utils = require 'mp.utils'

-- The radio player has its own permanent display (radio-epg.lua)
if (mp.get_property("input-ipc-server") or ""):find("mpv%-radio") then return end

-- Tvheadend host, passed in by __tvh.fish (--script-opts-append=tvh-host=...)
local TVH_HOST = mp.get_opt("tvh-host")
if TVH_HOST == "" then TVH_HOST = nil end
local OVERLAY_DURATION = 5
local MOUSE_THROTTLE = 10

local last_shown = 0

local function current_channel_uuid()
    local path = mp.get_property("path", "")
    return path:match("/stream/channel/([%w]+)")
end

local function fmt_time(unix)
    if not unix then return "--:--" end
    return os.date("%H:%M", unix)
end

local function fmt_duration(seconds)
    if not seconds or seconds < 0 then return "" end
    local mins = math.floor(seconds / 60)
    if mins < 60 then
        return string.format("%dm", mins)
    end
    local hours = math.floor(mins / 60)
    local rem = mins % 60
    if rem == 0 then
        return string.format("%dh", hours)
    end
    return string.format("%dh %dm", hours, rem)
end

-- Fetch now/next in the background, then call back with the entries (or nil)
local function fetch_epg(uuid, callback)
    local url = string.format(
        "http://%s/api/epg/events/grid?limit=2&channel=%s",
        TVH_HOST, uuid
    )
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = false,
        playback_only = false,
        args = {"curl", "-sS", "--max-time", "2", url},
    }, function(success, result)
        if not success or not result or result.status ~= 0 or not result.stdout then
            callback(nil)
            return
        end
        local parsed = utils.parse_json(result.stdout)
        callback(parsed and parsed.entries or nil)
    end)
end

local function build_overlay(entries, channel_name)
    local now_unix = os.time()
    local lines = {}

    table.insert(lines, string.format(
        "%s                                                %s",
        channel_name or "TV",
        os.date("%H:%M", now_unix)
    ))
    table.insert(lines, "")

    if entries[1] then
        local title = entries[1].title or "(untitled)"
        local elapsed = ""
        local remaining = ""

        if entries[1].start then
            local secs_in = now_unix - entries[1].start
            if secs_in >= 0 then
                elapsed = fmt_duration(secs_in) .. " elapsed"
            end
        end
        if entries[1].stop then
            local secs_left = entries[1].stop - now_unix
            if secs_left > 0 then
                remaining = fmt_duration(secs_left) .. " left"
            end
        end

        local timing
        if elapsed ~= "" and remaining ~= "" then
            timing = elapsed .. " · " .. remaining
        else
            timing = elapsed .. remaining
        end

        table.insert(lines, string.format("Now    %s   %s", title, timing))
    end

    if entries[2] then
        local title = entries[2].title or "(untitled)"
        local from_t = fmt_time(entries[2].start)
        local duration = ""
        if entries[2].start and entries[2].stop then
            duration = fmt_duration(entries[2].stop - entries[2].start)
        end

        local timing
        if duration ~= "" then
            timing = "from " .. from_t .. " · " .. duration
        else
            timing = "from " .. from_t
        end

        table.insert(lines, string.format("Next   %s   %s", title, timing))
    end

    return table.concat(lines, "\n")
end

local function show_overlay()
    local uuid = current_channel_uuid()
    if not uuid or not TVH_HOST then return end

    fetch_epg(uuid, function(entries)
        if not entries or #entries == 0 then return end
        local channel_name = entries[1].channelName or ""
        mp.osd_message(build_overlay(entries, channel_name), OVERLAY_DURATION)
    end)
end

local function on_mouse_move()
    local now = mp.get_time()
    if now - last_shown < MOUSE_THROTTLE then return end
    last_shown = now
    show_overlay()
end

local function on_keypress()
    last_shown = mp.get_time()
    show_overlay()
end

mp.observe_property("mouse-pos", "native", function(_, _) on_mouse_move() end)
mp.add_key_binding("g", "tv-epg-show", on_keypress)
