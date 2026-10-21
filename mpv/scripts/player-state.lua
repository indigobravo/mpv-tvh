-- player-state.lua
-- Runs inside the players (control sockets /tmp/mpv-tv, /tmp/mpv-radio,
-- /tmp/mpv-youtube, /tmp/mpv-music) and does the work their faceplates can't
-- do from outside:
--
--   state     TV, YouTube and music: publishes the player's state to
--             /tmp/mpv-<kind>.state.json whenever something changes and at
--             least once a second, for the control panel (faceplate.lua) in its
--             own window. On quit it's marked closed so the panel closes too.
--   VU        radio, YouTube and music: measures the audio with an astats filter and,
--             while `script-message vu-enable yes` is on, writes the levels to
--             /tmp/mpv-<kind>.vu about 30 times a second for the VU meter window
--             (vu-meter.lua), delayed by the audio buffer to match what you hear.
--   recent    YouTube: remembers the links you play (newest first, up to 30) in
--             mpv's state directory and adds them to the playlist after the
--             configured ones. `script-message yt-play <url> [title]` plays a
--             link now and `yt-queue <url> [title]` queues it next.
--   music     the CD player's queue (saved, and restored stopped at the same
--             track), recently played tracks (10), folders searched for music
--             files, STOP, repeat and shuffle; script-messages music-add <path>
--             [end|next|play],
--             music-remove <n>, music-move <from> <to>, music-play <n>,
--             music-stop, music-repeat, music-shuffle, music-history <n>,
--             music-clear (track numbers count from 1).

local mp = require 'mp'
local utils = require 'mp.utils'

local KIND = (mp.get_property("input-ipc-server") or ""):match("/mpv%-(%a+)$")
if KIND ~= "tv" and KIND ~= "radio" and KIND ~= "youtube" and KIND ~= "music" and KIND ~= "video" then return end
local YT = KIND == "youtube"

local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(data)
    f:close()
    os.rename(tmp, path)                                   -- readers never see half a file
end

---------------------------------------------------------------------------
-- YouTube: recent links
---------------------------------------------------------------------------

local RECENT_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-youtube-recent" })
local RECENT_MAX = 30
local recent = {}                                          -- { {url=, title=}, ... } newest first
local titles = {}                                          -- url -> title

local function load_recent()
    local f = io.open(RECENT_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local url, title = line:match("^(%S+)\t?(.*)$")
        if url then
            recent[#recent + 1] = { url = url, title = title }
            if title ~= "" then titles[url] = title end
        end
    end
    f:close()
end

local function save_recent()
    local dir = RECENT_FILE:match("(.*)/")
    if dir then utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false }) end
    local out = {}
    for _, r in ipairs(recent) do out[#out + 1] = r.url .. "\t" .. (r.title or "") end
    write_atomic(RECENT_FILE, table.concat(out, "\n") .. "\n")
end

local function remember(url, title)
    if not url or not url:match("^https?://") then return end
    for i = #recent, 1, -1 do
        if recent[i].url == url then
            title = (title ~= "" and title) or recent[i].title
            table.remove(recent, i)
        end
    end
    table.insert(recent, 1, { url = url, title = title or "" })
    while #recent > RECENT_MAX do table.remove(recent) end
    if title and title ~= "" then titles[url] = title end
    save_recent()
end

local function playlist_urls()
    local have = {}
    for i, e in ipairs(mp.get_property_native("playlist") or {}) do have[e.filename] = i end
    return have
end

-- Play a link now, or queue it after the current one (mpv 0.38+ inserts
-- directly; older versions append and move it into place)
local function add_link(url, title, play)
    if title and title ~= "" then titles[url] = title end
    local pos = mp.get_property_number("playlist-pos", -1)
    local ok = mp.commandv("loadfile", url, play and "insert-next-play" or "insert-next")
    if not ok then
        mp.commandv("loadfile", url, "append")
        local last = mp.get_property_number("playlist-count", 1) - 1
        if pos >= 0 and last > pos + 1 then mp.commandv("playlist-move", tostring(last), tostring(pos + 1)) end
        if play then mp.commandv("playlist-play-index", tostring(pos >= 0 and pos + 1 or last)) end
    end
end

if YT then
    load_recent()
    -- After the configured links, the recent ones not already listed
    mp.add_timeout(0.5, function()
        local have = playlist_urls()
        for i = #recent, 1, -1 do                          -- oldest first, so newest ends up last
            if not have[recent[i].url] then mp.commandv("loadfile", recent[i].url, "append") end
        end
    end)
    mp.register_event("file-loaded", function()
        remember(mp.get_property("path"), mp.get_property("media-title", ""))
    end)
    mp.register_script_message("yt-play", function(url, title) add_link(url, title, true) end)
    mp.register_script_message("yt-queue", function(url, title) add_link(url, title, false) end)
end

---------------------------------------------------------------------------
-- Music (CD player): queue, folders, recently played, stop / repeat / shuffle
---------------------------------------------------------------------------

local MUSIC = KIND == "music"
local VIDEO = KIND == "video"          -- the DV-252: a queue of files like the CD player's
local YT_OR_MUSIC = MUSIC or KIND == "youtube"
local music = { history = {}, stopped = false, repeat_mode = "off", shuffled = false }
local mark_dirty = function() end                           -- set by the state section

-- A file's name without folder, extension or leading track number
local function stem(path)
    local name = (path:match("([^/]+)/*$") or path):gsub("%.%w+$", "")
    local bare = name:gsub("^%d+%s*[%.%-_]?%s+", "")
    return bare ~= "" and bare or name
end

if MUSIC or VIDEO then
    local QUEUE_FILE   = mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. KIND .. "-queue" })
    local HISTORY_FILE = mp.command_native({ "expand-path", "~~state/mpv-tvh-" .. KIND .. "-history" })
    local HISTORY_MAX  = 10
    local AUDIO = {}
    for e in ("mp3 flac m4a aac alac ogg oga opus wav wave aif aiff aifc wma ape wv mpc dsf dff mka tta ac3"):gmatch("%S+") do
        AUDIO[e] = true
    end
    if VIDEO then                                -- video files, and audio (radio recordings)
        for e in ("mkv mp4 m4v mov avi webm ts m2ts mts wmv flv mpg mpeg ogv 3gp"):gmatch("%S+") do
            AUDIO[e] = true
        end
    end

    local function ensure_dir(path)
        local dir = path:match("(.*)/")
        if dir then utils.subprocess({ args = { "mkdir", "-p", dir }, cancellable = false }) end
    end

    -- Natural order: "2 Song" before "10 Song", ignoring case
    local function natural_key(s)
        return (s:lower():gsub("%d+", function(d) return string.format("%012d", tonumber(d)) end))
    end

    -- Audio files in a file or folder (folders searched in name order, with subfolders)
    local function audio_files(path, out)
        local info = utils.file_info(path)
        if not info then return out end
        if info.is_dir then
            local names = utils.readdir(path) or {}
            table.sort(names, function(a, b) return natural_key(a) < natural_key(b) end)
            for _, name in ipairs(names) do
                if name:sub(1, 1) ~= "." then audio_files(utils.join_path(path, name), out) end
            end
        elseif AUDIO[(path:match("%.(%w+)$") or ""):lower()] then
            out[#out + 1] = path
        end
        return out
    end

    local function load_lines(file)
        local lines, f = {}, io.open(file, "r")
        if not f then return lines end
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
        return lines
    end

    -- Recently played: newest first, path and title
    for _, line in ipairs(load_lines(HISTORY_FILE)) do
        local path, title = line:match("^([^\t]+)\t?(.*)$")
        if path then
            music.history[#music.history + 1] = { path = path, title = title ~= "" and title or stem(path) }
            titles[path] = music.history[#music.history].title
        end
    end
    local function save_history()
        ensure_dir(HISTORY_FILE)
        local out = {}
        for _, h in ipairs(music.history) do out[#out + 1] = h.path .. "\t" .. h.title end
        write_atomic(HISTORY_FILE, table.concat(out, "\n") .. "\n")
    end

    -- The queue is saved as it changes, and restored (stopped at the same
    -- track) when the player starts with nothing to play
    local function save_queue()
        ensure_dir(QUEUE_FILE)
        local out = { tostring(mp.get_property_number("playlist-pos", 0)) }
        for _, e in ipairs(mp.get_property_native("playlist") or {}) do out[#out + 1] = e.filename end
        write_atomic(QUEUE_FILE, table.concat(out, "\n") .. "\n")
    end
    local queue_dirty = false
    for _, p in ipairs({ "playlist-count", "playlist-pos", "playlist" }) do
        mp.observe_property(p, "native", function() queue_dirty = true end)
    end
    mp.add_periodic_timer(1, function()
        if queue_dirty then queue_dirty = false; save_queue() end
    end)
    mp.add_timeout(0.3, function()
        if mp.get_property_number("playlist-count", 0) > 0 then return end
        local lines = load_lines(QUEUE_FILE)
        local pos, added = tonumber(lines[1] or "") or 0, 0
        for i = 2, #lines do
            if utils.file_info(lines[i]) then
                mp.commandv("loadfile", lines[i], "append")
                added = added + 1
            end
        end
        if added > 0 then
            mp.set_property_bool("pause", true)
            music.stopped = true
            mp.commandv("playlist-play-index", tostring(math.max(0, math.min(pos, added - 1))))
        end
    end)

    mp.register_event("file-loaded", function()
        local path = mp.get_property("path", "")
        local t = mp.get_property("metadata/by-key/title")
        local a = mp.get_property("metadata/by-key/artist")
        local title = t or stem(path)
        titles[path] = title
        for i = #music.history, 1, -1 do
            if music.history[i].path == path then table.remove(music.history, i) end
        end
        table.insert(music.history, 1, { path = path, title = title })
        while #music.history > HISTORY_MAX do table.remove(music.history) end
        save_history()
        if music.stopped and MUSIC then mp.commandv("seek", "0", "absolute") end   -- video: resumes
        mark_dirty()
    end)
    mp.observe_property("pause", "bool", function(_, p)
        if p == false and music.stopped then music.stopped = false; mark_dirty() end
    end)

    local function idle() return mp.get_property_number("playlist-pos", -1) < 0 end

    -- From the faceplate and the playlist window (track numbers count from 1)
    local M = {}
    -- A file or folder: "end" (the default) adds it to the end of the queue,
    -- "next" after the track playing, "play" after it and plays it. Playing
    -- starts too if nothing was loaded.
    function M.add(path, mode)
        local files = path:match("^%a+://") and { path } or audio_files(path, {})   -- a stream: as is
        if #files == 0 then return end
        local pos = mp.get_property_number("playlist-pos", -1)
        local n0 = mp.get_property_number("playlist-count", 0)
        for _, f in ipairs(files) do mp.commandv("loadfile", f, "append") end
        if pos >= 0 and (mode == "next" or mode == "play") then
            for k = 1, #files do                     -- move them up, in order, after the current one
                mp.commandv("playlist-move", tostring(n0 + k - 1), tostring(pos + k))
            end
            n0 = pos + 1
        end
        if mode == "play" or pos < 0 then
            if VIDEO then mp.set_property("vid", "auto") end
            mp.commandv("playlist-play-index", tostring(n0))
            mp.set_property_bool("pause", false)
        end
    end
    function M.remove(i) mp.commandv("playlist-remove", tostring(tonumber(i) - 1)) end
    function M.move(from, to)                     -- put track `from` at position `to`
        from, to = tonumber(from), tonumber(to)
        if not from or not to or from == to then return end
        mp.commandv("playlist-move", tostring(from - 1), tostring(from < to and to or to - 1))
    end
    function M.play(i)
        if VIDEO then mp.set_property("vid", "auto") end
        mp.commandv("playlist-play-index", tostring(tonumber(i) - 1))
        mp.set_property_bool("pause", false)
    end
    function M.stop()                             -- like a CD: pause and back to the start
        mp.set_property_bool("pause", true)
        if not idle() then mp.commandv("seek", "0", "absolute") end
        music.stopped = true
        mark_dirty()
    end
    function M.repeat_()                          -- off -> all -> one -> off
        music.repeat_mode = ({ off = "all", all = "one", one = "off" })[music.repeat_mode]
        mp.set_property("loop-playlist", music.repeat_mode == "all" and "inf" or "no")
        mp.set_property("loop-file", music.repeat_mode == "one" and "inf" or "no")
        mark_dirty()
    end
    function M.shuffle()
        music.shuffled = not music.shuffled
        mp.commandv(music.shuffled and "playlist-shuffle" or "playlist-unshuffle")
        mark_dirty()
    end
    function M.history(n)                         -- queue a recently played track again
        local h = music.history[tonumber(n) or 0]
        if h then M.add(h.path) end
    end
    function M.clear()                            -- everything but the current track
        mp.commandv("playlist-clear")
    end
    for name, fn in pairs(M) do
        mp.register_script_message("music-" .. name:gsub("_$", ""), fn)
    end
end

-- YouTube: REPEAT (off, all, one) and SHUFFLE, with the CD player's messages
if KIND == "youtube" then
    mp.register_script_message("music-repeat", function()
        music.repeat_mode = ({ off = "all", all = "one", one = "off" })[music.repeat_mode]
        mp.set_property("loop-playlist", music.repeat_mode == "all" and "inf" or "no")
        mp.set_property("loop-file", music.repeat_mode == "one" and "inf" or "no")
        mark_dirty()
    end)
    mp.register_script_message("music-shuffle", function()
        music.shuffled = not music.shuffled
        mp.commandv(music.shuffled and "playlist-shuffle" or "playlist-unshuffle")
        mark_dirty()
    end)
end

-- STOP and PLAY, the same on every faceplate. CD and YouTube: like a CD
-- player, pause and back to the start. TV and radio: stop the stream (which
-- frees the tuner); PLAY starts the same channel again.
do
    local LIVE = KIND == "tv" or KIND == "radio"
    local live_pos = nil
    local function set_stopped(v, nosignal)
        music.stopped = v
        music.nosignal = (v and nosignal) or nil           -- stopped because it couldn't tune
        mp.set_property_native("user-data/tvh-nosignal", music.nosignal or false)
        mp.set_property_native("user-data/tvh-stopped", v)
        mp.set_property_native("user-data/tvh-stopped-index", (v and live_pos) and live_pos + 1 or 0)
        mark_dirty()
    end
    mp.register_script_message("player-stop", function()
        local pos = mp.get_property_number("playlist-pos", -1)
        if LIVE then
            if pos >= 0 then live_pos = pos end
            if not live_pos then return end
            mp.set_property("idle", "yes")            -- stay open with nothing playing
            mp.commandv("playlist-play-index", "none")
        else
            mp.set_property_bool("pause", true)
            if pos >= 0 then pcall(mp.commandv, "seek", "0", "absolute") end
        end
        set_stopped(true)
    end)
    -- The last track or video played, for PLAY after the queue has ended
    local last_pos = 0
    mp.observe_property("playlist-pos", "number", function(_, p) if p and p >= 0 then last_pos = p end end)

    mp.register_script_message("player-play", function()  -- PLAY · PAUSE
        if VIDEO then mp.set_property("vid", "auto") end   -- playing: show the picture
        local count = mp.get_property_number("playlist-count", 0)
        if not LIVE and mp.get_property_number("playlist-pos", -1) < 0 and count > 0 then
            -- finished (or nothing loaded): start the last one again
            mp.commandv("playlist-play-index", tostring(math.min(last_pos, count - 1)))
            mp.set_property_bool("pause", false)
            if music.stopped then set_stopped(false) end
        elseif music.stopped and LIVE and live_pos then
            mp.commandv("playlist-play-index", tostring(live_pos))
            mp.set_property_bool("pause", false)
        elseif music.stopped then
            mp.set_property_bool("pause", false)
        else
            mp.commandv("cycle", "pause")
        end
    end)
    -- PREV (rewind): back to the start of this track or video; within its
    -- first 5 seconds, the one before. Video with chapters: the same by
    -- chapter (mpv's chapter-seek-threshold). Live TV and radio: the
    -- channel before.
    mp.register_script_message("player-prev", function()
        if LIVE then mp.commandv("playlist-prev"); return end
        if VIDEO and mp.get_property_number("chapters", 0) > 0 then
            mp.commandv("add", "chapter", "-1")
            return
        end
        local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
        local first = mp.get_property_number("playlist-pos", 0) <= 0
        if pos and dur and (pos > 5 or first) then    -- (the first one: just its start)
            mp.commandv("seek", "0", "absolute")
        else
            mp.commandv("playlist-prev")
        end
    end)
    if LIVE then                                      -- a channel chosen while stopped plays
        mp.register_event("file-loaded", function() if music.stopped then set_stopped(false) end end)
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
            local list = mp.get_property_native("playlist") or {}
            local pos = mp.get_property_number("playlist-pos", -1)
            local was_stopped = music.stopped or pos < 0
            local at = was_stopped and live_pos or pos
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
            music.notice = { text = text, t = os.time() }
            mp.set_property_native("user-data/tvh-notice", music.notice)
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
                    if e.sched_status == "recording" and e.channel and music.stopped then
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
    elseif KIND == "youtube" then
        mp.observe_property("pause", "bool", function(_, p)
            if p == false and music.stopped then set_stopped(false) end
        end)
    end
end

-- Video: carry on where you left off (mpv's watch-later), saved whenever a
-- video is left, not only on quit; forgotten once one's watched to the end
if VIDEO then
    mp.add_hook("on_unload", 50, function()
        local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
        if pos and dur and dur > 0 and pos > dur * 0.95 then
            mp.commandv("delete-watch-later-config")
        elseif pos and pos > 30 then
            mp.commandv("write-watch-later-config")
        end
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
        "time-pos", "duration", "vid", "current-tracks/video/demux-h", "chapters", "chapter",
        "metadata/by-key/artist", "metadata/by-key/album", "metadata/by-key/title",
        "current-tracks/audio/demux-samplerate", "audio-params/format", "audio-codec-name",
        "loop-playlist", "loop-file", "volume", "audio-device",
    }

    local function write(closed)
        local s = { t = os.time(), closed = closed or nil, titles = {} }
        for _, p in ipairs(PROPS) do s[p] = mp.get_property_native(p) end
        for i, e in ipairs(mp.get_property_native("playlist") or {}) do
            s.titles[i] = e.title or titles[e.filename] or ((MUSIC or VIDEO) and stem(e.filename)) or e.filename
            if MUSIC or VIDEO or YT then s.paths = s.paths or {}; s.paths[i] = e.filename end   -- the playlist's table
        end
        if MUSIC or VIDEO then s.history = music.history end
        s.stopped = music.stopped
        s.nosignal = music.nosignal
        s.player_notice = music.notice
        s.stopped_index = mp.get_property_native("user-data/tvh-stopped-index")
        if YT_OR_MUSIC then s.repeat_mode, s.shuffled = music.repeat_mode, music.shuffled end
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
-- VU meter levels: for the VU meter window (radio, YouTube, music) and the
-- preamp's level bars (all players). `open` in the file is the VU window's.
---------------------------------------------------------------------------

do
    local VU_FILE = "/tmp/mpv-" .. KIND .. ".vu"
    local vu_on, hist, vu_theme = false, {}, "blue"
    local for_preamp = false

    local function write_vu(open, l, r, pl, pr)
        local idx = mp.get_property_number("playlist-pos", 0) + 1
        local title = mp.get_property("playlist/" .. (idx - 1) .. "/title")
            or titles[mp.get_property("path", "")] or mp.get_property("media-title", "")
        write_atomic(VU_FILE, string.format("%d %d %s %.1f %.1f %.1f %.1f\n%s\n", os.time(), open and 1 or 0,
            vu_theme, l or -90, r or -90, pl or -90, pr or -90, title))
    end

    -- RMS and peak per channel of each audio frame
    mp.commandv("af", "add",
        "@vu:lavfi=[astats=metadata=1:reset=1:measure_perchannel=RMS_level+Peak_level:measure_overall=none]")
    local function level(m, ch, what)
        local v = tonumber(m["lavfi.astats." .. ch .. "." .. what] or "")
        return (v and v == v) and math.max(-90, v) or -90       -- silence is "-inf"
    end

    mp.add_periodic_timer(1 / 30, function()
        if not vu_on and not for_preamp then return end
        local now = mp.get_time()
        local m = mp.get_property_native("af-metadata/vu") or {}
        local s = { t = now, l = level(m, 1, "RMS_level"), pl = level(m, 1, "Peak_level") }
        s.r = m["lavfi.astats.2.RMS_level"] and level(m, 2, "RMS_level") or s.l      -- mono: both
        s.pr = m["lavfi.astats.2.Peak_level"] and level(m, 2, "Peak_level") or s.pl
        if mp.get_property_bool("core-idle", true) then s.l, s.r, s.pl, s.pr = -90, -90, -90, -90 end
        hist[#hist + 1] = s
        -- Audio is filtered ahead of playback by the audio buffer: send the
        -- reading from that long ago so the needles match what you hear
        local delay = mp.get_property_number("audio-buffer", 0.2) + 0.05
        while #hist > 1 and hist[2].t <= now - delay do table.remove(hist, 1) end
        write_vu(vu_on, hist[1].l, hist[1].r, hist[1].pl, hist[1].pr)
    end)

    -- From the faceplate: vu-enable yes|no [theme]
    mp.register_script_message("vu-enable", function(on, theme)
        vu_on, hist = on == "yes", {}
        if theme and theme:match("^%a+$") then vu_theme = theme end
        if not vu_on then write_vu(false) end
    end)
    -- From the preamp: vu-preamp yes|no
    mp.register_script_message("vu-preamp", function(on)
        for_preamp, hist = on == "yes", {}
        if not for_preamp and not vu_on then write_vu(false) end
    end)
    mp.register_event("shutdown", function() write_vu(false) end)
end
