-- Reload config automatically when init.lua changes.
-- Resolves the symlink so edits made in the repo checkout are picked up too.
local configDir = (hs.fs.pathToAbsolute(hs.configdir .. "/init.lua") or hs.configdir):match("(.*)/")
configWatcher = hs.pathwatcher.new(configDir, function()
  hs.reload()
end):start()

hs.window.animationDuration = 0   -- instant window moves/resizes

----------------------------------------------------------------------
-- Launchers (global): bottom row key 1 = TV, key 2 = radio
----------------------------------------------------------------------

local FISH = "PATH=/opt/homebrew/bin:$PATH nohup /opt/homebrew/bin/fish -c '%s' >/dev/null 2>&1 &"

-- Find a running player by its control socket (works across Spaces)
local function playerApp(kind)
  local out = hs.execute("pgrep -f '[i]pc-server=/tmp/mpv-" .. kind .. "'")
  local pid = tonumber(out:match("%d+"))
  return pid and hs.application.applicationForPID(pid)
end

-- Send a command to one player via its socket (in the background, so it never blocks)
local function playerCommand(kind, json)
  hs.execute(string.format([[(echo '%s' | nc -U -w 1 /tmp/mpv-%s >/dev/null &)]], json, kind))
end

-- Not running: start it.  In background: bring to front.  Already in front: toggle mute.
local function playerLauncher(kind, cmd)
  return function()
    local app = playerApp(kind)
    if not app then
      hs.execute(string.format(FISH, cmd))
    elseif app:isFrontmost() then
      playerCommand(kind, '{"command":["cycle","mute"]}')
    else
      app:activate()
    end
  end
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f13", playerLauncher("tv",    "tv --default"))
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f16", playerLauncher("radio", "radio --default"))

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
  hs.alert.closeAll(0)
  hs.alert.show(string.format("🔊 %d%%", math.floor(v + 0.5)), 0.6)
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f18", function() changeVolume(-VOL_STEP) end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "f19", function() changeVolume(VOL_STEP) end)

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

local function updateProfile(appName)
  if ownProfile[appName] then default:exit() else default:enter() end
end

appWatcher = hs.application.watcher.new(function(name, event)
  if event == hs.application.watcher.activated then updateProfile(name) end
end):start()

updateProfile(hs.application.frontmostApplication():name())

hs.alert.show("Hammerspoon config loaded")
