-- Reload config automatically when init.lua changes.
-- Resolves the symlink so edits made in the repo checkout are picked up too.
local configDir = (hs.fs.pathToAbsolute(hs.configdir .. "/init.lua") or hs.configdir):match("(.*)/")
configWatcher = hs.pathwatcher.new(configDir, function()
  hs.reload()
end):start()

hs.window.animationDuration = 0   -- instant window moves/resizes

----------------------------------------------------------------------
-- Sources (global): bottom row key 1 = TV, key 2 = tuner (radio), key 3 =
-- network (YouTube), Alt (key 4) + key 3 = CD, Alt + key 1 = video player,
-- Alt + key 2 = the recorder.
-- The sources go through the preamp
-- (preamp.lua), which chooses what you hear; the other sources keep running.
----------------------------------------------------------------------

local FISH = "PATH=/opt/homebrew/bin:$PATH nohup /opt/homebrew/bin/fish -c '%s' >/dev/null 2>&1 &"

-- Find a running mpv by its control socket (works across Spaces)
local function playerApp(kind)
  local out = hs.execute("pgrep -f '[i]pc-server=/tmp/mpv-" .. kind .. "'")
  local pid = tonumber(out:match("%d+"))
  return pid and hs.application.applicationForPID(pid)
end

-- Send a command to one mpv via its socket (in the background, so it never blocks)
local function playerCommand(kind, json)
  hs.execute(string.format([[(echo '%s' | nc -U -w 1 /tmp/mpv-%s >/dev/null &)]], json, kind))
end

-- Bring a window forward once its mpv is up (it takes a moment to start)
local function activateWhenUp(kind, tries)
  local app = playerApp(kind)
  if app then
    app:activate()
  elseif tries > 0 then
    hs.timer.doAfter(0.15, function() activateWhenUp(kind, tries - 1) end)
  end
end

-- Each source's faceplate (the radio is its own) and, for the CD, its library
local SOURCES = {
  tv    = { kind = "tv",      face = "panel-tv",      lib = "lib-tv" },   -- lib: the guide
  tuner = { kind = "radio",   face = "radio" },
  net   = { kind = "youtube", face = "panel-youtube" },
  cd    = { kind = "music",   face = "panel-music", lib = "lib-music" },
  vid   = { kind = "video",   face = "panel-video", lib = "lib-video" },
}

local function chosenInput()
  local f = io.open("/tmp/mpv-preamp.input", "r")
  if not f then return nil end
  local id = f:read("*l")
  f:close()
  return id
end

-- Preamp off: start it with this source (it starts the source too).
-- Another source chosen, or this one behind other windows: choose it and
-- bring its faceplate forward. Chosen and in front: mute or unmute it.
local refreshProfile                   -- the pad's routing (defined below)

local function sourceKey(id)
  local src = SOURCES[id]
  return function()
    if not playerApp("preamp") then
      hs.execute(string.format(FISH, "preamp " .. id))
      activateWhenUp(src.face, 40)
      hs.timer.doAfter(6, function() refreshProfile() end)
      return
    end
    local face = playerApp(src.face)
    local lib = src.lib and playerApp(src.lib)
    local function front(a) return a ~= nil and a:isFrontmost() end
    if chosenInput() == id and (front(face) or front(lib)) then
      playerCommand(src.kind, '{"command":["cycle","mute"]}')
      return
    end
    playerCommand("preamp", '{"command":["script-message","preamp-select","' .. id .. '"]}')
    if lib then lib:activate()
    elseif face then face:activate()
    else activateWhenUp(src.face, 40) end
  end
end

-- The YT key's chord already includes Option, so holding the pad's Alt key
-- doesn't change what it sends. Instead, watch for Option held on its own for
-- a moment before the chord arrives: then the key means the CD.
local altSince = nil
altWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local f = e:getFlags()
  if f.alt and not (f.ctrl or f.cmd or f.shift) then
    altSince = altSince or hs.timer.secondsSinceEpoch()
  elseif not f.alt then
    altSince = nil
  end
  return false
end):start()

local function altHeld()
  return altSince ~= nil and hs.timer.secondsSinceEpoch() - altSince > 0.15
end

-- Alt + Radio: the recorder. Off: start it. On: REC, and again: STOP.
local function recorderKey()
  if not playerApp("recorder") then
    hs.execute(string.format(FISH, "recorder"))
    return
  end
  local f = io.open("/tmp/mpv-recorder.state", "r")
  local state = f and f:read("*l") or ""
  if f then f:close() end
  local msg = state:match("^rec") and "recorder-stop" or "recorder-rec"
  playerCommand("recorder", '{"command":["script-message","' .. msg .. '"]}')
end

local tvKey, vidKey = sourceKey("tv"), sourceKey("vid")
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f13", function()
  if altHeld() then vidKey() else tvKey() end
end)

local tunerKey = sourceKey("tuner")
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f16", function()
  if altHeld() then recorderKey() else tunerKey() end
end)

local netKey, cdKey = sourceKey("net"), sourceKey("cd")
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f17", function()
  if altHeld() then cdKey() else netKey() end
end)

----------------------------------------------------------------------
-- STACK on the preamp (hammerspoon://tvh-view?mode=stack|full&input=):
-- two rows under the preamp. The TV faceplate (the primary) is always the
-- first; the other faceplates share the second, on top of each other, the
-- chosen one in front. The recorder goes under them. mode=full puts them back
----------------------------------------------------------------------

local FACES = { tv = "panel-tv", tuner = "radio", net = "panel-youtube", cd = "panel-music",
                vid = "panel-video" }
local spreadFrames = {}                      -- window id -> where it was before stacking

local function mpvWindow(kind)
  local app = playerApp(kind)
  return app and (app:mainWindow() or app:allWindows()[1])
end

-- A faceplate's home from its --geometry in config.yml (pixels, from the
-- top left of the main screen, under the menu bar) in points
local CONFIG_OPTS = { tv = "tv.panel_opts", tuner = "radio.mpv_opts", net = "youtube.panel_opts",
                      cd = "music.panel_opts", vid = "video.panel_opts", recorder = "recorder.panel_opts" }
local function configFrame(id, win)
  local key = CONFIG_OPTS[id]
  if not key then return nil end
  local cfg = os.getenv("MPV_TVH_CONFIG") or (os.getenv("HOME") .. "/.config/mpv-tvh/config.yml")
  local out = hs.execute(string.format("/opt/homebrew/bin/yq '.%s // [] | .[]' '%s'", key, cfg)) or ""
  local x, y = out:match("%-%-geometry=%d+x%d+%+(%d+)%+(%d+)")
  if not x then return nil end
  local screen = hs.screen.primaryScreen()
  local scale = screen:currentMode().scale or 2
  local f, sf = win:frame(), screen:frame()   -- mpv places below the menu bar
  return hs.geometry.rect(sf.x + tonumber(x) / scale, sf.y + tonumber(y) / scale, f.w, f.h)
end

----------------------------------------------------------------------
-- The big windows go directly under the stack, at the faceplates' width,
-- down to the bottom of the screen, in front: the TV guide (lib-tv) under
-- the TV's and the radio's faceplates; the CD's and the video player's
-- libraries under their own faceplate too. Our faceplates they cover are
-- hidden while they're open.
----------------------------------------------------------------------

-- The screen's height below the menu bar, in pixels, and its scale, for the
-- faceplates: they open a guide or library at its full height straight
-- away, rather than it opening short and then being stretched
local function noteScreen()
  local screen = hs.screen.primaryScreen()
  local scale = screen:currentMode().scale or 2
  local f = io.open("/tmp/mpv-tvh-screen", "w")
  if f then f:write(string.format("%d %d\n", math.floor(screen:frame().h * scale), scale)); f:close() end
end
noteScreen()
screenWatcher = hs.screen.watcher.new(noteScreen):start()

local UNDER = { ["lib-tv"] = "panel-tv", ["lib-radio"] = "radio", ["lib-music"] = "panel-music",
                ["lib-video"] = "panel-video" }
local hiddenBy = {}                          -- big window -> apps hidden under it

local function unhideUnder(kind)
  for _, app in ipairs(hiddenBy[kind] or {}) do pcall(function() app:unhide() end) end
  hiddenBy[kind] = nil
end

local function placeUnder(kind)
  local g, tv = mpvWindow(kind), mpvWindow("panel-tv")
  if not g then return end
  local own = mpvWindow(UNDER[kind] or "")
  local tf = (tv or own) and (tv or own):frame()
  if not tf then return end
  -- The lowest of the faceplates that stay showing, in the stack's column
  local bottom = tf.y + tf.h
  for _, w in ipairs({ mpvWindow("radio"), own }) do
    local f = w and w:frame()
    if f and math.abs(f.x - tf.x) < 4 then bottom = math.max(bottom, f.y + f.h) end
  end
  local gap = 10
  local y = bottom + gap
  local sf = (tv or own):screen():frame()
  local h = sf.y + sf.h - gap - y            -- all the way down: more rows
  local frame = hs.geometry.rect(tf.x, y, tf.w, h)
  g:setFrame(frame)
  g:raise()
  unhideUnder(kind)
  local hidden = {}
  for _, k in ipairs({ "panel-youtube", "panel-music", "panel-video", "recorder" }) do
    local w = k ~= UNDER[kind] and mpvWindow(k)
    local cut = w and w:frame():intersect(frame)
    if cut and cut.w > 0 and cut.h > 0 then
      local app = w:application()
      app:hide()
      hidden[#hidden + 1] = app
    end
  end
  hiddenBy[kind] = hidden
end

local function placeAllUnder()
  for kind in pairs(UNDER) do if mpvWindow(kind) then placeUnder(kind) end end
end

-- From a faceplate, once it's opened its guide or library
hs.urlevent.bind("tvh-guide", function() placeUnder("lib-tv") end)
hs.urlevent.bind("tvh-under", function(_, params)
  if UNDER[params.kind or ""] then placeUnder(params.kind) end
end)

hs.urlevent.bind("tvh-view", function(_, params)
  local windows = { preamp = mpvWindow("preamp"), recorder = mpvWindow("recorder") }
  for id, kind in pairs(FACES) do windows[id] = mpvWindow(kind) end

  if params.mode ~= "stack" then
    for id, win in pairs(windows) do
      -- Where its config puts it (one that opened straight into the stack
      -- was never anywhere else), or else where it was before stacking
      local home = configFrame(id, win) or spreadFrames[win:id()]
      if home then win:setFrame(home) end
    end
    spreadFrames = {}
    placeAllUnder()
    return
  end

  -- The preamp stays where it is, at the top; the TV under it, then the
  -- other faceplates on top of each other (sizes unchanged)
  local pre = windows.preamp
  if not pre then return end
  local pf = spreadFrames[pre:id()] or pre:frame()
  local gap = 10
  local function place(win, y)
    local f = win:frame()
    if not spreadFrames[win:id()] then spreadFrames[win:id()] = f end
    win:setFrame(hs.geometry.rect(pf.x, y, f.w, f.h))
    return f.h
  end
  local y = pf.y + pf.h + gap
  if windows.tv then y = y + place(windows.tv, y) + gap end
  local rowH = 0
  for id in pairs(FACES) do
    if id ~= "tv" and windows[id] then rowH = math.max(rowH, place(windows[id], y)) end
  end
  if rowH > 0 then y = y + rowH + gap end
  if windows.recorder then place(windows.recorder, y) end
  -- The chosen faceplate to the front of its row, without taking the focus
  -- (so the preamp's buttons keep working); the TV is always showing
  local front = windows[params.input]
  if front then front:raise() end
  if windows.tv then windows.tv:raise() end
  placeAllUnder()
end)

----------------------------------------------------------------------
-- The secondary picture slot (under the TV window): every source's windows
-- stay open there, stacked. hammerspoon://tvh-raise?input= (from the
-- preamp, on choosing a source) brings that source's ones to the front,
-- without taking the focus.
----------------------------------------------------------------------

local KIND_OF = { tv = "tv", tuner = "radio", net = "youtube", cd = "music", vid = "video" }

hs.urlevent.bind("tvh-raise", function(_, params)
  local kind = KIND_OF[params.input or ""]
  if not kind then return end
  local list = { "vu-" .. kind }
  if kind == "youtube" or kind == "video" then list[#list + 1] = kind end   -- its picture
  if kind == "tv" then list[#list + 1] = "tv" end      -- the picture, over the radio's VU meter
  if kind == "music" or kind == "youtube" then list[#list + 1] = "list-" .. kind end
  for _, k in ipairs(list) do
    local win = mpvWindow(k)
    if win then win:raise() end
  end
end)

----------------------------------------------------------------------
-- The Mac's volume, mute and sound device, for the preamp's display:
-- written to /tmp/mpv-tvh.audio ("volume muted name") whenever they change
----------------------------------------------------------------------

local AUDIO_FILE = "/tmp/mpv-tvh.audio"
local watchedDevice, publishTimer = nil, nil

local function publishAudio()
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then return end
  local f = io.open(AUDIO_FILE, "w")
  if not f then return end
  f:write(string.format("%d %d %s\n", math.floor((dev:outputVolume() or 0) + 0.5),
    dev:outputMuted() and 1 or 0, dev:name() or ""))
  f:close()
  playerCommand("preamp", '{"command":["script-message","preamp-audio"]}')
end

local function publishSoon()                 -- a change fires several events
  if publishTimer then publishTimer:stop() end
  publishTimer = hs.timer.doAfter(0.05, publishAudio)
end

local function watchDevice()
  if watchedDevice then watchedDevice:watcherStop() end
  watchedDevice = hs.audiodevice.defaultOutputDevice()
  if watchedDevice then
    watchedDevice:watcherCallback(function() publishSoon() end):watcherStart()
  end
  publishSoon()
end

hs.audiodevice.watcher.setCallback(function(event)
  if event == "dOut" then watchDevice() end
end)
hs.audiodevice.watcher.start()
watchDevice()

----------------------------------------------------------------------
-- Volume knob: fine-grained system volume
----------------------------------------------------------------------

local VOL_STEP = 2   -- percent per knob click (the Mac's own keys move ~6%)

local function changeVolume(delta)
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then return end
  local v = math.max(0, math.min(100, (dev:outputVolume() or 0) + delta))
  dev:setOutputVolume(v)
  if delta > 0 and dev:outputMuted() then dev:setOutputMuted(false) end
  publishSoon()
  if not playerApp("preamp") then            -- the preamp shows it otherwise
    hs.alert.closeAll(0)
    hs.alert.show(string.format("🔊 %d%%", math.floor(v + 0.5)), 0.6)
  end
end

-- (knob 2 is bound further down: in the guide and libraries it scrolls)

----------------------------------------------------------------------
-- Default profile: pad keys 1-8 (F13-F20) when no app profile applies
----------------------------------------------------------------------

local function send(mods, key)
  return function() hs.eventtap.keyStroke(mods, key, 0) end
end

local function toggleMic()
  local mic = hs.audiodevice.defaultInputDevice()
  if not mic then return end
  local muted = not mic:inputMuted()
  if mic:setInputMuted(muted) then
    hs.alert.show((muted and "🎙️ Mic muted" or "🎙️ Mic live") .. " (" .. mic:name() .. ")")
  else
    hs.alert.show("⚠️ Can't mute " .. mic:name())
  end
end

local function moveToNextScreen()
  local win = hs.window.focusedWindow()
  if win then win:moveToScreen(win:screen():next()) end
end

local savedFrames = {}
local function toggleMaximise()
  local win = hs.window.focusedWindow()
  if not win then return end
  local id = win:id()
  if savedFrames[id] and win:frame():equals(win:screen():frame()) then
    win:setFrame(savedFrames[id])
    savedFrames[id] = nil
  else
    savedFrames[id] = win:frame()
    win:maximize()
  end
end

local default = hs.hotkey.modal.new()
default:bind({}, "f13", hs.caffeinate.lockScreen)            -- 1: lock screen
default:bind({}, "f14", send({"cmd", "shift"}, "["))         -- 2: previous tab
default:bind({}, "f15", send({"cmd", "shift"}, "]"))         -- 3: next tab
default:bind({}, "f16", toggleMic)                           -- 4: mic mute
default:bind({}, "f17", send({"cmd", "ctrl", "shift"}, "4")) -- 5: screenshot area to clipboard
default:bind({}, "f18", send({"cmd", "shift"}, "t"))         -- 6: reopen closed tab
default:bind({}, "f19", send({"cmd"}, "w"))                  -- 7: close tab/window
default:bind({}, "f20", moveToNextScreen)                    -- 8: window to other display
default:bind({"alt"}, "f20", toggleMaximise)                 -- Alt+8: maximise / restore

----------------------------------------------------------------------
-- Profile switching: apps listed here handle the F-keys themselves
----------------------------------------------------------------------

local ownProfile = { mpv = true }

----------------------------------------------------------------------
-- The pad follows the preamp: while one of our windows is in front (and
-- the preamp is on), keys 1-8, their Alt versions and knob 1 go to the
-- chosen source's faceplate (script-message pad-key), whichever window
-- has the focus. The library windows keep the arrows and Return for
-- browsing.
----------------------------------------------------------------------

local FACE_OF = { tv = "panel-tv", tuner = "radio", net = "panel-youtube", cd = "panel-music",
                  vid = "panel-video" }
local route = hs.hotkey.modal.new()

local function routeKey(mods, key, padName)
  route:bind(mods, key, function()
    local face = FACE_OF[chosenInput() or ""]
    if face then
      playerCommand(face, '{"command":["script-message","pad-key","' .. padName .. '"]}')
    end
  end)
end
for i = 13, 20 do routeKey({}, "f" .. i, "F" .. i) end
for i = 16, 20 do routeKey({"alt"}, "f" .. i, "Alt+F" .. i) end
routeKey({}, "up", "UP")
routeKey({}, "down", "DOWN")
routeKey({}, "return", "ENTER")
routeKey({"alt"}, "up", "Alt+UP")
routeKey({"alt"}, "down", "Alt+DOWN")
routeKey({"alt"}, "return", "Alt+ENTER")

local function isLibrary(app)
  for _, kind in ipairs({ "lib-music", "lib-video", "lib-tv", "lib-radio" }) do
    local lib = playerApp(kind)
    if lib and app and lib:pid() == app:pid() then return true end
  end
  return false
end

local function updateProfile(appName, app)
  if ownProfile[appName] then
    default:exit()
    if playerApp("preamp") and not isLibrary(app) then route:enter() else route:exit() end
  else
    route:exit()
    default:enter()
  end
end

----------------------------------------------------------------------
-- The knobs. Knob 1 sends its own chords (ctrl-alt-cmd-F14/F15), so it can
-- be told from the arrow keys. In front of a guide or library: knob 1
-- moves sideways (the guide's time, the library's columns), knob 2 up and
-- down, and Alt + knob 2 is the volume. Elsewhere knob 1 is Up/Down (Alt +
-- turn: Alt+Up/Down), as before, and knob 2 the volume.
----------------------------------------------------------------------

local function frontLibrary()
  local app = hs.application.frontmostApplication()
  for _, kind in ipairs({ "lib-tv", "lib-radio", "lib-music", "lib-video" }) do
    local lib = playerApp(kind)
    if lib and app and lib:pid() == app:pid() then return kind end
  end
end

local function libKey(kind, name)
  playerCommand(kind, '{"command":["keypress","' .. name .. '"]}')
end

local function knob1(dir)                    -- dir: "UP" (anticlockwise) or "DOWN"
  local alt = altHeld()
  local lib = frontLibrary()
  if lib then
    if alt then libKey(lib, dir) else libKey(lib, dir == "UP" and "LEFT" or "RIGHT") end
    return
  end
  local app = hs.application.frontmostApplication()
  local face = FACE_OF[chosenInput() or ""]
  if app and ownProfile[app:name()] and playerApp("preamp") and face then
    playerCommand(face, '{"command":["script-message","pad-key","' .. (alt and "Alt+" or "") .. dir .. '"]}')
  else                                       -- an arrow key, without the chord's modifiers
    local key = dir == "UP" and "up" or "down"
    local mods = alt and { "alt" } or {}
    hs.eventtap.event.newKeyEvent(mods, key, true):post()
    hs.eventtap.event.newKeyEvent(mods, key, false):post()
  end
end

local function knob2(dir)                    -- dir: -1 (anticlockwise) or 1
  local lib = frontLibrary()
  if lib and not altHeld() then libKey(lib, dir < 0 and "UP" or "DOWN")
  else changeVolume(dir * VOL_STEP) end
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f14", function() knob1("UP") end, nil, function() knob1("UP") end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f15", function() knob1("DOWN") end, nil, function() knob1("DOWN") end)
-- Knob 2's press (ctrl-alt-cmd-F20): Enter in a guide or library (Alt:
-- Alt+Enter), otherwise mute
local function knob2Press()
  local lib = frontLibrary()
  if lib then libKey(lib, altHeld() and "Alt+ENTER" or "ENTER"); return end
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev then dev:setOutputMuted(not dev:outputMuted()); publishSoon() end
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f20", knob2Press)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f18", function() knob2(-1) end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f19", function() knob2(1) end)

appWatcher = hs.application.watcher.new(function(name, event, app)
  if event == hs.application.watcher.activated then updateProfile(name, app)
  elseif event == hs.application.watcher.launched and app then
    -- A guide or library opening: put it in its place once its window is up
    local pid, tries = app:pid(), 0
    local function try()
      tries = tries + 1
      local which
      for kind in pairs(UNDER) do
        local a = playerApp(kind)
        if a and a:pid() == pid then which = kind end
      end
      if not which then
        if tries < 3 then hs.timer.doAfter(0.2, try) end   -- not (yet) one of those
      elseif mpvWindow(which) then placeUnder(which)
      elseif tries < 15 then hs.timer.doAfter(0.1, try) end
    end
    hs.timer.doAfter(0.1, try)
  elseif event == hs.application.watcher.terminated and next(hiddenBy) then
    hs.timer.doAfter(0.3, function()                -- one closed: show what it hid
      for kind in pairs(hiddenBy) do
        if not playerApp(kind) then unhideUnder(kind) end
      end
    end)
  end
end):start()

refreshProfile = function()
  local app = hs.application.frontmostApplication()
  if app then updateProfile(app:name(), app) end
end
refreshProfile()

----------------------------------------------------------------------
-- Alt + 1: POWER. Preamp off: switch it on (it starts every source, on
-- TV). On: everything off.
----------------------------------------------------------------------

hs.hotkey.bind({"alt"}, "f13", function()
  if playerApp("preamp") then
    playerCommand("preamp", '{"command":["script-message","preamp-power"]}')
    hs.timer.doAfter(2, refreshProfile)
  else
    hs.execute(string.format(FISH, "preamp"))
    activateWhenUp("preamp", 40)
    hs.timer.doAfter(6, refreshProfile)
  end
end)

hs.alert.show("Hammerspoon config loaded")
