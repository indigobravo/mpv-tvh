-- mpv-tvh.lua: the macro pad and window handling for mpv-tvh.
--
-- Load it from your own ~/.hammerspoon/init.lua with
--
--   require("mpv-tvh")
--
-- (install.fish links this file into ~/.hammerspoon and adds that line).
-- It binds the pad's chords (the bottom row, the knobs, Alt + 1) everywhere,
-- and keys 1-8 (F13-F20) only while an mpv-tvh window is in front. Outside
-- mpv-tvh, F13-F20 are yours: bind them in your init.lua, and leave them
-- alone while mpv is in front (see M.isMpv below).

local M = {}

-- Reload Hammerspoon when this file changes in the repo checkout (the
-- link in ~/.hammerspoon is resolved to find it)
do
  local here = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = (hs.fs.pathToAbsolute(here) or here):match("(.*)/")
  if dir then M.watcher = hs.pathwatcher.new(dir, function() hs.reload() end):start() end
end

hs.window.animationDuration = 0   -- instant window moves (the guide under the stack)

----------------------------------------------------------------------
-- Sources (global): bottom row key 1 = TV, key 2 = tuner (radio), key 3 =
-- GUIDE (the chosen source's guide). The sources go through the preamp
-- (preamp.lua), which chooses what you hear; the other one keeps running.
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

-- Each source's faceplate (the radio is its own) and its guide
local SOURCES = {
  tv    = { kind = "tv",    face = "panel-tv", lib = "lib-tv" },
  tuner = { kind = "radio", face = "radio",    lib = "lib-radio" },
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
local resetLayer = function() end      -- back to layer 1, channels (defined below)

local function sourceKey(id)
  local src = SOURCES[id]
  return function()
    if not playerApp("preamp") then
      resetLayer()                     -- switching on: the channels
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

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f13", sourceKey("tv"))
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f16", sourceKey("tuner"))

-- The third key: open or close the chosen source's guide. Preamp off:
-- switch it on first.
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f17", function()
  if not playerApp("preamp") then
    resetLayer()
    hs.execute(string.format(FISH, "preamp"))
    activateWhenUp("preamp", 40)
    hs.timer.doAfter(6, function() refreshProfile() end)
    return
  end
  local src = SOURCES[chosenInput() or ""] or SOURCES.tv
  playerCommand(src.face, '{"command":["script-message","pad-key","GUIDE"]}')
end)

local function mpvWindow(kind)
  local app = playerApp(kind)
  return app and (app:mainWindow() or app:allWindows()[1])
end

----------------------------------------------------------------------
-- The guides go directly under the stack, at the faceplates' width, down
-- to the bottom of the screen, in front: the TV's (lib-tv) and the radio's
-- (lib-radio), under both faceplates.
----------------------------------------------------------------------

-- The screen's height below the menu bar, in pixels, and its scale, for the
-- faceplates: they open a guide at its full height straight
-- away, rather than it opening short and then being stretched
local function noteScreen()
  local screen = hs.screen.primaryScreen()
  local scale = screen:currentMode().scale or 2
  local f = io.open("/tmp/mpv-tvh-screen", "w")
  if f then f:write(string.format("%d %d\n", math.floor(screen:frame().h * scale), scale)); f:close() end
end
noteScreen()
M.screenWatcher = hs.screen.watcher.new(noteScreen):start()

local UNDER = { ["lib-tv"] = "panel-tv", ["lib-radio"] = "radio" }

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
end

-- From a faceplate, once it's opened its guide
hs.urlevent.bind("tvh-guide", function() placeUnder("lib-tv") end)
hs.urlevent.bind("tvh-under", function(_, params)
  if UNDER[params.kind or ""] then placeUnder(params.kind) end
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

-- (knob 2 is bound further down: in the guides it scrolls)

-- mpv itself handles keys 1-8 when the preamp isn't on (input.conf), so
-- your own F13-F20 bindings should stand aside while it's in front
function M.isMpv(app) return app ~= nil and app:name() == "mpv" end

----------------------------------------------------------------------
-- The pad's layers. The bottom right key is LAYER (ctrl-alt-cmd-F12): a tap
-- moves to the next layer, 1 CH -> 2 TRANSPORT -> 3 DISPLAY -> 1, and
-- holding it gives layer 2 for the keys pressed meanwhile (and, in a
-- guide, the Alt version of the knobs). After 10 seconds without the pad
-- it goes back to layer 1. The preamp shows the layer (preamp-layer).
--
--   key   1 CH        2 TRANSPORT   3 DISPLAY
--   1-4   channels    PREV NEXT     DIM COLOUR
--                     PLAY STOP     SCROLL CLOCK
--   5-8   channels    RECORDINGS    SETUP - -
--                     FULL MUTE     POWER
--                     POWER
--
-- Layer 1's keys only go to mpv-tvh while one of its windows is in front
-- (elsewhere they're yours); layers 2 and 3 work whatever's in front, while
-- the preamp is on. In a guide, keys and knobs keep the guide's own jobs.
----------------------------------------------------------------------

local FACE_OF = { tv = "panel-tv", tuner = "radio" }
local LAYERS = { "CH", "TRANSPORT", "DISPLAY" }
local IDLE = 10                              -- seconds, then back to layer 1

local layer, held, usedWhileHeld = 1, false, false
local idleTimer = nil
local route = hs.hotkey.modal.new()          -- layer 1: channels, while mpv-tvh's in front
local layered = hs.hotkey.modal.new()        -- layers 2 and 3: everywhere

local function faceKey(name)                 -- the chosen source's faceplate does it
  local face = FACE_OF[chosenInput() or ""]
  if face then playerCommand(face, '{"command":["script-message","pad-key","' .. name .. '"]}') end
end

local function preampMsg(...)
  local args = { "script-message", ... }
  playerCommand("preamp", hs.json.encode({ command = args }))
end

local function isLibrary(app)                -- a guide
  for _, kind in ipairs({ "lib-tv", "lib-radio" }) do
    local lib = playerApp(kind)
    if lib and app and lib:pid() == app:pid() then return true end
  end
  return false
end

local function frontLibrary()
  local app = hs.application.frontmostApplication()
  for _, kind in ipairs({ "lib-tv", "lib-radio" }) do
    local lib = playerApp(kind)
    if lib and app and lib:pid() == app:pid() then return kind end
  end
end

local function libKey(kind, name)
  playerCommand(kind, '{"command":["keypress","' .. name .. '"]}')
end

local function current() return held and 2 or layer end

-- Which key bindings are live: layer 1's channels while mpv-tvh is in
-- front, layers 2 and 3 everywhere (not in a guide)
local function updateProfile(app)
  app = app or hs.application.frontmostApplication()
  local on = playerApp("preamp") ~= nil
  local guide = isLibrary(app)
  if on and current() == 1 and M.isMpv(app) and not guide then route:enter() else route:exit() end
  if on and current() ~= 1 and not guide then layered:enter() else layered:exit() end
  if M.onLayerChange then pcall(M.onLayerChange, current()) end
end
refreshProfile = function() updateProfile() end

-- Your own F13-F20 bindings stand aside while this is true (see the docs)
function M.layered() return current() ~= 1 and playerApp("preamp") ~= nil end
function M.layer() return current() end

local LAYER_FILE = "/tmp/mpv-tvh.layer"     -- for a preamp that's just starting
local function announce()
  local f = io.open(LAYER_FILE, "w")
  if f then f:write(current(), "\n"); f:close() end
  preampMsg("preamp-layer", tostring(current()), held and "hold" or "")
  if not playerApp("preamp") then
    hs.alert.closeAll(0)
    hs.alert.show("PAD  " .. current() .. "  " .. LAYERS[current()], 0.8)
  end
  updateProfile()
end

local function setLayer(n)
  layer = n
  if idleTimer then idleTimer:stop(); idleTimer = nil end
  if layer ~= 1 then
    idleTimer = hs.timer.doAfter(IDLE, function() idleTimer = nil; if not held then setLayer(1) end end)
  end
  announce()
end

resetLayer = function()
  held = false
  setLayer(1)
end

local function touch()                       -- the pad's been used: the idle time starts again
  if held then usedWhileHeld = true end
  if layer ~= 1 then setLayer(layer) end
end

local holdTimer = nil
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f12",
  function()                                 -- down: layer 2 for the keys pressed while it's held
    held, usedWhileHeld = true, false
    updateProfile()
    holdTimer = hs.timer.doAfter(0.3, function() holdTimer = nil; if held then announce() end end)
  end,
  function()                                 -- up: a tap moves to the next layer
    held = false
    if holdTimer then holdTimer:stop(); holdTimer = nil end
    if usedWhileHeld then announce() else setLayer(layer % #LAYERS + 1) end
  end)

-- Keys 1-8, layer by layer
local function power()
  resetLayer()                               -- off or on: the pad goes back to the channels
  if playerApp("preamp") then
    preampMsg("preamp-power")
    hs.timer.doAfter(2, refreshProfile)
  else
    hs.execute(string.format(FISH, "preamp"))
    activateWhenUp("preamp", 40)
    hs.timer.doAfter(6, refreshProfile)
  end
end

local KEYS = {
  [2] = { function() faceKey("PREV") end, function() faceKey("NEXT") end,
          function() faceKey("PLAY") end, function() faceKey("STOP") end,
          function() faceKey("RECORDINGS") end, function() faceKey("FULL") end,
          function() preampMsg("preamp-mute") end, power },
  [3] = { function() preampMsg("preamp-display", "DIM") end, function() preampMsg("preamp-display", "COLOUR") end,
          function() preampMsg("preamp-display", "SCROLL") end, function() preampMsg("preamp-display", "CLOCK") end,
          function() preampMsg("preamp-setup") end, nil, nil, power },
}
M.KEYS = KEYS                                -- (for the docs' pictures: what each key does)

for i = 1, 8 do
  route:bind({}, "f" .. (12 + i), function() touch(); faceKey("F" .. (12 + i)) end)
  layered:bind({}, "f" .. (12 + i), function()
    touch()
    local fn = (KEYS[current()] or {})[i]
    if fn then fn() end
  end)
end

----------------------------------------------------------------------
-- The knobs (their own chords: knob 1 ctrl-alt-cmd-F14/F15, press F11;
-- knob 2 F18/F19, press F20). In a guide: knob 1 moves through time (or
-- the page's columns), knob 2 up and down, a press is Enter; with LAYER
-- held, knob 1 goes up and down, knob 2 is the volume and a press is
-- Alt + Enter. Elsewhere, by layer:
--
--               1 CH                  2 TRANSPORT     3 DISPLAY
--   knob 1      channel (mpv-tvh in   seek 5 s        colour
--               front; else arrows)
--   press       play / pause          play / pause    DIM
--   knob 2      volume                volume          volume
--   press       mute                  mute            mute
----------------------------------------------------------------------

local function arrow(key)
  hs.eventtap.event.newKeyEvent({}, key, true):post()
  hs.eventtap.event.newKeyEvent({}, key, false):post()
end

local function knob1(dir)                    -- dir: "UP" (anticlockwise) or "DOWN"
  touch()
  local lib = frontLibrary()
  if lib then
    if held then libKey(lib, dir) else libKey(lib, dir == "UP" and "LEFT" or "RIGHT") end
    return
  end
  local on, l = playerApp("preamp") ~= nil, current()
  if on and l == 2 then faceKey(dir)                                      -- seek
  elseif on and l == 3 then preampMsg("preamp-display", "COLOUR", dir == "UP" and "-1" or "1")
  elseif on and M.isMpv(hs.application.frontmostApplication()) then faceKey("Alt+" .. dir)   -- channel
  else arrow(dir == "UP" and "up" or "down") end
end

local function knob1Press()
  touch()
  local lib = frontLibrary()
  if lib then libKey(lib, held and "Alt+ENTER" or "ENTER"); return end
  local on, l = playerApp("preamp") ~= nil, current()
  if on and l == 3 then preampMsg("preamp-display", "DIM")
  elseif on and (l == 2 or M.isMpv(hs.application.frontmostApplication())) then faceKey("PLAY")
  else arrow("return") end
end

local function knob2(dir)                    -- dir: -1 (anticlockwise) or 1
  touch()
  local lib = frontLibrary()
  if lib and not held then libKey(lib, dir < 0 and "UP" or "DOWN")
  else changeVolume(dir * VOL_STEP) end
end

local function knob2Press()
  touch()
  local lib = frontLibrary()
  if lib then libKey(lib, held and "Alt+ENTER" or "ENTER"); return end
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev then dev:setOutputMuted(not dev:outputMuted()); publishSoon() end
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f14", function() knob1("UP") end, nil, function() knob1("UP") end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f15", function() knob1("DOWN") end, nil, function() knob1("DOWN") end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f11", knob1Press)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f20", knob2Press)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f18", function() knob2(-1) end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f19", function() knob2(1) end)

M.appWatcher = hs.application.watcher.new(function(name, event, app)
  if event == hs.application.watcher.activated then updateProfile(app)
  elseif event == hs.application.watcher.launched and app then
    -- A guide opening: put it in its place once its window is up
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
  end
end):start()

resetLayer()                                 -- (re)loaded: layer 1, and the preamp told

return M
