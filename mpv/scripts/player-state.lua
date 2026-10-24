-- player-state.lua
-- Runs inside the players (control sockets /tmp/mpv-tv and /tmp/mpv-radio)
-- and does the work their faceplates can't do from outside:
--
--   state     publishes the player's state to /tmp/mpv-<kind>.state.json
--             whenever something changes and at least once a second, for
--             the TV's faceplate (faceplate.lua, in its own window) and the
--             preamp. On quit it's marked closed so the faceplate closes too.
--   levels    measures the audio with an astats filter and, while the preamp
--             asks (`script-message vu-preamp yes`), writes the levels to
--             /tmp/mpv-<kind>.vu for its level bars.
--   live      STOP (frees the tuner), PLAY, starting stopped on the default
--             channel, new channels from the presets (tvh-load), and staying
--             put when a channel won't tune.
--   playback  `script-message tvh-recording <url> [title] [channel]` (the guide's WATCH)
--             plays a Tvheadend recording in this player; a channel key, STOP
--             or the end of it goes back to the channel you were on.

local mp = require 'mp'
local utils = require 'mp.utils'

local KIND = (mp.get_property("input-ipc-server") or ""):match("/mpv%-(%a+)$")
if KIND ~= "tv" and KIND ~= "radio" then return end

local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(data)
    f:close()
    os.rename(tmp, path)                                   -- readers never see half a file
end

local titles = {}                                          -- url -> title
local live = { stopped = false }                           -- stopped, nosignal, notice, rec
local mark_dirty = function() end                          -- set by the state section

-- STOP and PLAY. TV and radio: stop the stream (which frees the tuner);
-- PLAY starts the same channel again. A recording: STOP goes back to the
-- channel, stopped.
do
    local live_pos = nil
    local function set_stopped(v, nosignal)
        live.stopped = v
        live.nosignal = (v and nosignal) or nil            -- stopped because it couldn't tune
        mp.set_property_native("user-data/tvh-nosignal", live.nosignal or false)
        mp.set_property_native("user-data/tvh-stopped", v)
        mp.set_property_native("user-data/tvh-stopped-index", (v and live_pos) and live_pos + 1 or 0)
        mark_dirty()
    end

    -- Recordings: one at a time, added after the channels and taken off
    -- again when you leave it
    local function rec_index()
        if not live.rec then return nil end
        for i, e in ipairs(mp.get_property_native("playlist") or {}) do
            if e.id == live.rec.id then return i - 1 end
        end
    end
    local function rec_drop()
        local i = rec_index()
        local back = live.rec and live.rec.back
        live.rec = nil
        mp.set_property_native("user-data/tvh-recording", false)
        mp.set_property_native("user-data/tvh-recording-channel", false)
        if i then mp.commandv("playlist-remove", tostring(i)) end
        mark_dirty()
        return back
    end
    local function rec_playing()
        local i = rec_index()
        return i ~= nil and i == mp.get_property_number("playlist-pos", -1)
    end

    mp.register_script_message("player-stop", function()
        local pos = mp.get_property_number("playlist-pos", -1)
        if rec_playing() then
            live_pos = live.rec.back
            mp.set_property("idle", "yes")
            mp.commandv("playlist-play-index", "none")
            rec_drop()
        else
            if pos >= 0 then live_pos = pos end
            if not live_pos then return end
            mp.set_property("idle", "yes")            -- stay open with nothing playing
            mp.commandv("playlist-play-index", "none")
        end
        set_stopped(true)
    end)

    mp.register_script_message("player-play", function()  -- PLAY · PAUSE
        if live.stopped and live_pos then
            mp.commandv("playlist-play-index", tostring(live_pos))
            mp.set_property_bool("pause", false)
        elseif live.stopped then
            mp.set_property_bool("pause", false)
        else
            mp.commandv("cycle", "pause")
        end
    end)
    -- PREV: the channel before; in a recording, back 30 seconds
    mp.register_script_message("player-prev", function()
        if rec_playing() then mp.commandv("seek", "-30"); return end
        mp.commandv("playlist-prev")
    end)
    mp.register_script_message("player-next", function()
        if rec_playing() then mp.commandv("seek", "30"); return end
        mp.commandv("playlist-next")
    end)

    -- WATCH from the guide: tvh-recording <url> [title] [channel it was on]
    mp.register_script_message("tvh-recording", function(url, title, channel)
        if not url or url == "" then return end
        local pos = mp.get_property_number("playlist-pos", -1)
        local back = live.rec and live.rec.back
        if rec_playing() or not back then back = (pos >= 0 and not rec_playing()) and pos or live_pos or 0 end
        if live.rec then rec_drop() end
        title = (title and title ~= "") and title or url
        local m3u = "/tmp/mpv-" .. KIND .. ".recording.m3u"
        write_atomic(m3u, "#EXTM3U\n#EXTINF:-1," .. (title:gsub("\n", " ")) .. "\n" .. url .. "\n")
        mp.commandv("loadlist", m3u, "append")
        local list = mp.get_property_native("playlist") or {}
        local e = list[#list]
        if not e then return end
        titles[url] = title
        live.rec = { id = e.id, back = back, title = title, channel = (channel or "") ~= "" and channel or nil }
        mp.set_property_native("user-data/tvh-recording", title)
        mp.set_property_native("user-data/tvh-recording-channel", live.rec.channel or false)
        mp.commandv("playlist-play-index", tostring(#list - 1))
        mp.set_property_bool("pause", false)
        mark_dirty()
    end)

    -- A channel chosen while stopped plays; leaving a recording drops it
    mp.register_event("file-loaded", function()
        if live.stopped then set_stopped(false) end
        if live.rec and not rec_playing() then rec_drop() end
    end)
    -- The end of a recording: back to its channel, stopped
    mp.register_event("end-file", function(ev)
        if ev.reason == "eof" and live.rec and ev.playlist_entry_id == live.rec.id then
            mp.add_timeout(0, function()
                if not live.rec or rec_playing() then return end
                live_pos = rec_drop()
                mp.set_property("idle", "yes")
                mp.commandv("playlist-play-index", "none")
                set_stopped(true)
            end)
        end
    end)

    -- Started stopped (tv / radio --default without `start:`): the
    -- channels loaded, on the default one, nothing playing until PLAY
    local list = mp.get_opt("tvh-list")
    if list and list ~= "" then
        mp.commandv("loadlist", list, "append")
        mp.commandv("playlist-play-index", "none")    -- (should this mpv have started it)
        live_pos = tonumber(mp.get_opt("tvh-pos")) or 0
        set_stopped(true)
    end
    -- New channels (the presets changed: __tvh --reload): the same
    -- channel stays chosen if it's still there; stopped stays stopped
    mp.register_script_message("tvh-load", function(path)
        local was_rec = live.rec ~= nil
        local back = was_rec and live.rec.back
        if was_rec then rec_drop() end
        local list = mp.get_property_native("playlist") or {}
        local pos = mp.get_property_number("playlist-pos", -1)
        local was_stopped = live.stopped or pos < 0 or was_rec
        local at = was_rec and back or (was_stopped and live_pos or pos)
        local url = at and list[at + 1] and list[at + 1].filename
        mp.commandv("loadlist", path, "replace")
        if was_stopped then mp.commandv("playlist-play-index", "none") end
        local idx = 0
        for i, e in ipairs(mp.get_property_native("playlist") or {}) do
            if url and e.filename == url then idx = i - 1 end
        end
        if was_stopped then
            live_pos = idx
            set_stopped(true)
        else
            mp.commandv("playlist-play-index", tostring(idx))
        end
        mp.add_timeout(5, function() os.remove(path) end)
        mark_dirty()
    end)
    -- A channel that won't open (Tvheadend has no tuner free, say): stay
    -- on it, stopped, rather than trying the next one and then quitting.
    -- If Tvheadend is busy recording a channel in this player's list,
    -- switch to that one (the tuner can give us that) and say so;
    -- otherwise the faceplate shows NO SIGNAL, and PLAY tries again.
    mp.set_property("idle", "yes")
    local function tvh()                            -- SETUP's address, or the config's
        local f = io.open((os.getenv("HOME") or "") .. "/.config/mpv-tvh/presets.json", "r")
        local j = f and utils.parse_json(f:read("*a") or "")
        if f then f:close() end
        return (j and j.host and j.host ~= "") and j.host or (mp.get_opt("tvh-host") or "")
    end
    local switched_at = 0
    local function say(text)                       -- for the faceplate, a few seconds
        live.notice = { text = text, t = os.time() }
        mp.set_property_native("user-data/tvh-notice", live.notice)
        mark_dirty()
    end
    local function to_recording(idx)
        local TVH = tvh()
        if TVH == "" or os.time() - switched_at < 20 then return end   -- once, not round and round
        mp.command_native_async({
            name = "subprocess", capture_stdout = true, playback_only = false,
            args = { "curl", "-sS", "--netrc-optional", "--max-time", "4",
                     "http://" .. TVH .. "/api/dvr/entry/grid_upcoming?limit=200" },
        }, function(ok, res)
            local j = ok and res and res.status == 0 and utils.parse_json(res.stdout or "")
            for _, e in ipairs(j and j.entries or {}) do
                if e.sched_status == "recording" and e.channel and live.stopped then
                    for i, p in ipairs(mp.get_property_native("playlist") or {}) do
                        if i - 1 ~= idx and (p.filename or ""):find("/stream/channel/" .. e.channel, 1, true) then
                            switched_at = os.time()
                            say("TUNER BUSY RECORDING " .. (e.disp_title or e.title or ""):upper()
                                .. "  ·  SWITCHED TO " .. (p.title or e.channelname or ""):upper())
                            mp.commandv("playlist-play-index", tostring(i - 1))
                            return
                        end
                    end
                end
            end
        end)
    end
    local failed
    mp.add_hook("on_load_fail", 50, function()
        failed = mp.get_property_number("playlist-pos", -1)
    end)
    mp.register_event("end-file", function(ev)
        if ev.reason ~= "error" then return end
        if live.rec and ev.playlist_entry_id == live.rec.id then   -- a recording that won't play
            failed = nil
            live_pos = rec_drop()
            mp.commandv("playlist-play-index", "none")
            set_stopped(true)
            say("CAN'T PLAY THAT RECORDING")
            return
        end
        local idx = failed
        for i, e in ipairs(mp.get_property_native("playlist") or {}) do
            if e.id == ev.playlist_entry_id then idx = i - 1 end
        end
        failed = nil
        if not idx or idx < 0 then return end
        live_pos = idx
        mp.commandv("playlist-play-index", "none")
        set_stopped(true, true)
        to_recording(idx)
    end)
end

---------------------------------------------------------------------------
-- State for the faceplates and the preamp (all players)
---------------------------------------------------------------------------

do
    local FILE = "/tmp/mpv-" .. KIND .. ".state.json"
    local PROPS = {
        "path", "media-title", "playlist-pos", "playlist-count", "pause", "mute",
        "core-idle", "paused-for-cache", "demuxer-cache-duration", "fullscreen",
        "audio-params/channel-count", "video-params/h", "video-params/aspect",
        "sub-visibility", "sid", "metadata/by-key/icy-title",
        "time-pos", "duration", "vid", "current-tracks/video/demux-h",
        "current-tracks/audio/demux-samplerate", "audio-params/format", "audio-codec-name",
        "volume", "audio-device",
    }

    local function write(closed)
        local s = { t = os.time(), closed = closed or nil, titles = {} }
        for _, p in ipairs(PROPS) do s[p] = mp.get_property_native(p) end
        for i, e in ipairs(mp.get_property_native("playlist") or {}) do
            s.titles[i] = e.title or titles[e.filename] or e.filename
        end
        s.stopped = live.stopped
        s.nosignal = live.nosignal
        s.player_notice = live.notice
        s.recording = live.rec and live.rec.title or nil      -- playing back a Tvheadend recording
        s.recording_channel = live.rec and live.rec.channel or nil
        s.stopped_index = mp.get_property_native("user-data/tvh-stopped-index")
        -- The sound device, when this player has its own (otherwise the Mac's)
        local dev = s["audio-device"]
        if dev and dev ~= "auto" then
            for _, d in ipairs(mp.get_property_native("audio-device-list") or {}) do
                if d.name == dev then s.audio_out = d.description end
            end
            s.audio_out = s.audio_out or dev
        end
        write_atomic(FILE, utils.format_json(s) or "{}")
    end

    local dirty = true
    mark_dirty = function() dirty = true end
    for _, p in ipairs(PROPS) do
        if p ~= "demuxer-cache-duration" and p ~= "time-pos" then
            mp.observe_property(p, "native", function() dirty = true end)
        end
    end
    mp.add_periodic_timer(0.25, function()
        if dirty then dirty = false; write() end
    end)
    mp.add_periodic_timer(1, function() dirty = true end)  -- heartbeat, position, buffer level
    mp.register_event("shutdown", function() write(true) end)
end

---------------------------------------------------------------------------
-- Levels for the preamp's level bars, while it asks (vu-preamp yes): written
-- to /tmp/mpv-<kind>.vu about 30 times a second, delayed by the audio buffer
-- to match what you hear
---------------------------------------------------------------------------

do
    local VU_FILE = "/tmp/mpv-" .. KIND .. ".vu"
    local hist = {}
    local for_preamp = false

    local function write_vu(l, r, pl, pr)
        write_atomic(VU_FILE, string.format("%d 0 levels %.1f %.1f %.1f %.1f\n", os.time(),
            l or -90, r or -90, pl or -90, pr or -90))
    end

    -- RMS and peak per channel of each audio frame
    mp.commandv("af", "add",
        "@vu:lavfi=[astats=metadata=1:reset=1:measure_perchannel=RMS_level+Peak_level:measure_overall=none]")
    local function level(m, ch, what)
        local v = tonumber(m["lavfi.astats." .. ch .. "." .. what] or "")
        return (v and v == v) and math.max(-90, v) or -90       -- silence is "-inf"
    end

    mp.add_periodic_timer(1 / 30, function()
        if not for_preamp then return end
        local now = mp.get_time()
        local m = mp.get_property_native("af-metadata/vu") or {}
        local s = { t = now, l = level(m, 1, "RMS_level"), pl = level(m, 1, "Peak_level") }
        s.r = m["lavfi.astats.2.RMS_level"] and level(m, 2, "RMS_level") or s.l      -- mono: both
        s.pr = m["lavfi.astats.2.Peak_level"] and level(m, 2, "Peak_level") or s.pl
        if mp.get_property_bool("core-idle", true) then s.l, s.r, s.pl, s.pr = -90, -90, -90, -90 end
        hist[#hist + 1] = s
        -- Audio is filtered ahead of playback by the audio buffer: send the
        -- reading from that long ago so the bars match what you hear
        local delay = mp.get_property_number("audio-buffer", 0.2) + 0.05
        while #hist > 1 and hist[2].t <= now - delay do table.remove(hist, 1) end
        write_vu(hist[1].l, hist[1].r, hist[1].pl, hist[1].pr)
    end)

    -- From the preamp: vu-preamp yes|no
    mp.register_script_message("vu-preamp", function(on)
        for_preamp, hist = on == "yes", {}
        if not for_preamp then write_vu() end
    end)
    mp.register_event("shutdown", function() write_vu() end)
end
