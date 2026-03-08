-- Rocket Silo Launch Control (OC + ProjectRed + GTNH OC Additions)
-- Bundled cable side: EAST
--
-- Door logic is INVERTED:
--   Redstone ON  = Door CLOSED
--   Redstone OFF = Door OPEN
--
-- Blue INPUT on EAST:
--   Blue ON = "rocket heading home" signal
--
-- AUTO (key 5):
-- Door OPEN -> wait -> Lights OFF -> wait -> Alarm ON -> Launch
-- wait -> Door CLOSE
-- wait for BLUE -> Door OPEN
-- wait for dock -> Door CLOSE -> wait -> Lights ON
-- UNLOAD until cargo_unloader reports TARGET_EMPTY
-- then LOAD until cargo_loader reports OUT_OF_ITEMS (while docked)
--
-- Uses:
--  cargo_unloader.getInvStatus(): bool, string  (TARGET_NOT_FOUND, TARGET_EMPTY, SUCCESS)
--  cargo_loader.getStatus(): bool, string      (OUT_OF_ITEMS, TARGET_NOT_FOUND, TARGET_FULL, TARGET_LACKS_INVENTORY, SUCCESS)
--  cargo_launch_controller.isRocketDocked(): bool
--
-- Source: README methods list :contentReference[oaicite:1]{index=1}

local component = require("component")
local event = require("event")
local term = require("term")
local sides = require("sides")
local colors = require("colors")
local os = require("os")
local computer = require("computer")
local serialization = require("serialization")

local SCRIPT_VERSION = "0.2.7"
local UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/skydaz10/oc-mission-control/main/manifest.lua"

local function loadConfig()
  local ok, cfg = pcall(function()
    local fn = loadfile("/home/node_config.lua")
    if not fn then return nil end
    local res = fn()
    if type(res) == "table" then return res end
    return nil
  end)
  if ok then return cfg end
end

local CFG = loadConfig() or {}
if type(CFG.UPDATE_MANIFEST_URL) == "string" and CFG.UPDATE_MANIFEST_URL ~= "" then
  UPDATE_MANIFEST_URL = CFG.UPDATE_MANIFEST_URL
end

local rs = component.redstone
local modem = component.isAvailable("modem") and component.modem or nil
local tunnel = component.isAvailable("tunnel") and component.tunnel or nil
local me = component.isAvailable("me_controller") and component.me_controller or nil
local launchCtrl = component.isAvailable("cargo_launch_controller") and component.cargo_launch_controller or nil
local unloader  = component.isAvailable("cargo_unloader") and component.cargo_unloader or nil
local loader    = component.isAvailable("cargo_loader") and component.cargo_loader or nil
local transposer = component.isAvailable("transposer") and component.transposer or nil

------------------------------------------------
-- CONFIG
------------------------------------------------
local SIDE = sides.north
local ON, OFF = 255, 0

-- Network (wired modem)
local NET_PORT = 4242
local NET_HELLO_PERIOD = 2.0
local NET_STATUS_PERIOD = 2.0
local NET_SEEN_TTL = 30.0

-- Network mode:
-- Prefer modem. In the relay+linked-card setup, cross-dim relays forward modem packets.
-- Set to "modem" to force the intended topology.
local NET_FORCE_MODE = "modem"
local NET_MODE = (NET_FORCE_MODE == "modem" and modem and "modem")
  or (NET_FORCE_MODE == "tunnel" and tunnel and "tunnel")
  or (NET_FORCE_MODE == nil and (modem and "modem" or (tunnel and "tunnel") or "none"))
  or "none"

-- Timings (seconds)
local DOOR_OPEN_SETTLE           = 4
local PRE_LAUNCH_DELAY           = 5
local ALARM_TAKEOFF_EXTRA        = 2
local AFTER_LAUNCH_WAIT          = 12
local AFTER_LANDING_LIGHTS_DELAY = 5

-- Launch controller timings
local LAUNCH_ENABLE_HOLD     = 8      -- keep launch controller enabled at least this long
local LAUNCH_CONFIRM_TIMEOUT = 60     -- how long we'll wait to see undock
local DOCKED_FALSE_CONFIRM   = 2      -- number of consecutive "not docked" polls required
local LAUNCH_POLL            = 0.5

-- Cargo machine polling
local STATUS_POLL = 1.0

-- Unload logic
local UNLOAD_ENABLE_DELAY = 2         -- after enabling unloader, wait a bit before checking status
local UNLOAD_EMPTY_CONFIRM = 3        -- require TARGET_EMPTY this many times in a row

-- Load logic
local LOADER_MIN_ON_SECONDS = 10      -- always leave loader on at least this long
local LOADER_OUT_CONFIRM    = 3       -- require OUT_OF_ITEMS this many times in a row
local LOADER_TIMEOUT        = 180     -- safety cap (seconds); set huge if you want

-- Bundled channels (ProjectRed bundled colors)
local CH_DOOR   = colors.red      -- inverted output
local CH_LIGHTS = colors.white
local CH_ALARM  = colors.yellow
local CH_HOME   = colors.blue     -- INPUT ONLY: rocket heading home

------------------------------------------------
-- STATE
------------------------------------------------
local doorOpen = true
local lightsOn = false
local alarmOn  = false
local armed    = false
local busy     = false
local autoStandby = false
local statusLine = "Ready"

-- Network state
local siloId = (computer.getLabel and computer.getLabel()) or nil
if not siloId or siloId == "" then
  siloId = "SILO-" .. tostring(computer.address()):sub(1, 6)
end

local hqAddr = nil
local lastHelloAt = 0
local lastStatusAt = 0
local pendingHelloId = nil
local seenMsg = {}

local abortRequested = false

-- Mission state (HQ-driven AUTO)
local currentMissionId = nil
local currentOutpostId = nil
local currentDstFreq = nil
local lastMissionId = nil
local lastMissionResult = nil -- "DONE" | "ABORT" | nil
local needEmptyItems = 0
local needEmptyFluids = 0
local missionMode = false
local netHomeInbound = false
local netHomeMissionId = nil

-- Silo staging (transposer + tile.cargo)
local loaderInvSide = nil

-- AE2 craftables (EMPTYCELL / EMPTYFLUID)
local craftEmptyCell = nil
local craftEmptyFluid = nil

local PREFLIGHT_TIMEOUT = 600
local PREFLIGHT_POLL = 1

-- Launch controller frequency cache (source freq is set in-world; HQ uses it for routing)
local lastFreqPollAt = 0
local cachedHomeFreq = nil
local cachedHomeFreqValid = nil
local cachedDstFreq = nil
local cachedDstFreqValid = nil

------------------------------------------------
-- Helpers
------------------------------------------------
-- Forward declarations (network layer needs these)
local abortAuto, autoCycle, isDocked

local function now()
  return computer.uptime()
end

local function msgId()
  -- good enough uniqueness for LAN
  return tostring(math.floor(now() * 1000)) .. "-" .. tostring(math.random(100000, 999999))
end

local function cleanupSeen()
  local cutoff = now() - NET_SEEN_TTL
  for k, t in pairs(seenMsg) do
    if t < cutoff then seenMsg[k] = nil end
  end
end

local function netSend(addr, pkt)
  if NET_MODE == "tunnel" then
    if not tunnel then return false end
    pkt.v = 1
    pkt.from = pkt.from or siloId
    pkt.ts = pkt.ts or now()
    local s = serialization.serialize(pkt)
    return tunnel.send(s)
  end
  if NET_MODE ~= "modem" then return false end
  if not modem or not addr then return false end
  pkt.v = 1
  pkt.from = pkt.from or siloId
  pkt.ts = pkt.ts or now()
  local s = serialization.serialize(pkt)
  return modem.send(addr, NET_PORT, s)
end

local function netBroadcast(pkt)
  if NET_MODE == "tunnel" then
    -- no broadcast in tunnel; just send to the linked endpoint
    return netSend(nil, pkt)
  end
  if NET_MODE ~= "modem" then return false end
  if not modem then return false end
  pkt.v = 1
  pkt.from = pkt.from or siloId
  pkt.ts = pkt.ts or now()
  local s = serialization.serialize(pkt)
  return modem.broadcast(NET_PORT, s)
end

local function netAck(addr, ackMsgId)
  return netSend(addr, {kind = "ACK", msgId = msgId(), payload = {ack = ackMsgId}})
end

local function getState()
  -- Cache reads to avoid spamming component calls.
  if launchCtrl and (now() - lastFreqPollAt >= 1.0) then
    lastFreqPollAt = now()
    local ok1, v1 = pcall(function() return launchCtrl.getFrequency() end)
    if ok1 then cachedHomeFreq = v1 end
    local ok2, v2 = pcall(function() return launchCtrl.isValidFrequency() end)
    if ok2 then cachedHomeFreqValid = v2 end
    local ok3, v3 = pcall(function() return launchCtrl.getDstFrequency() end)
    if ok3 then cachedDstFreq = v3 end
    local ok4, v4 = pcall(function() return launchCtrl.isValidDstFrequency() end)
    if ok4 then cachedDstFreqValid = v4 end
  end

  return {
    siloId = siloId,
    armed = armed,
    busy = busy,
    autoStandby = autoStandby,
    doorOpen = doorOpen,
    lightsOn = lightsOn,
    alarmOn = alarmOn,
    docked = isDocked(),
    statusLine = statusLine,
    homeFreq = cachedHomeFreq,
    homeFreqValid = cachedHomeFreqValid,
    dstFreqCtrl = cachedDstFreq,
    dstFreqValid = cachedDstFreqValid,
    missionId = currentMissionId,
    outpostId = currentOutpostId,
    dstFreq = currentDstFreq,
    lastMissionId = lastMissionId,
    lastMissionResult = lastMissionResult,
    needEmptyItems = needEmptyItems,
    needEmptyFluids = needEmptyFluids,
  }
end

local function netStatus(reason)
  if NET_MODE ~= "tunnel" and not hqAddr then return end
  netSend(hqAddr, {
    kind = "STATUS",
    msgId = msgId(),
    to = "HQ",
    payload = {
      reason = reason,
      state = getState(),
    },
  })
  lastStatusAt = now()
end

local function netHello(force)
  if NET_MODE == "none" then return end
  if (not force) and (now() - lastHelloAt < NET_HELLO_PERIOD) then return end
  if not pendingHelloId then
    pendingHelloId = msgId()
  end
  netBroadcast({
    kind = "HELLO",
    msgId = pendingHelloId,
    to = "HQ",
    payload = {
      role = "silo",
      siloId = siloId,
      caps = {
        launch = launchCtrl ~= nil,
        unload = unloader ~= nil,
        load = loader ~= nil,
      },
      state = getState(),
    }
  })
  lastHelloAt = now()
end

local function maybeHeartbeat()
  if hqAddr and (now() - lastStatusAt >= NET_STATUS_PERIOD) then
    netStatus("heartbeat")
  end
  if (not hqAddr) then
    netHello(false)
  end
end

local function handleCmd(payload)
  if type(payload) ~= "table" then return end

  if payload.abort then
    abortRequested = true
    -- If not busy, abort immediately to put things in a safe state.
    if not busy then abortAuto() end
    netStatus("cmd:abort")
    return
  end

  if payload.arm ~= nil then
    if not busy then
      armed = not not payload.arm
      statusLine = armed and "Armed" or "Disarmed"
      netStatus("cmd:arm")
    end
  end

  if payload.setFreq and launchCtrl then
    local src = tonumber(payload.setFreq.src)
    local dst = tonumber(payload.setFreq.dst)
    if src then pcall(function() launchCtrl.setFrequency(src) end) end
    if dst then pcall(function() launchCtrl.setDstFrequency(dst) end) end
    netStatus("cmd:setFreq")
  end

  if payload.autoStart then
    if not busy then
      autoStandby = true
      statusLine = "AUTO standby"
      netStatus("cmd:autoStandby")
    end
  end

  if payload.startMission then
    local m = payload.startMission
    if type(m) ~= "table" then return end
    if busy then return end
    if not autoStandby then
      statusLine = "Reject: not in AUTO standby"
      netStatus("reject:not_standby")
      return
    end

    currentMissionId = m.missionId or msgId()
    currentOutpostId = m.outpostId
    currentDstFreq = tonumber(m.dstFreq)
    needEmptyItems = tonumber(m.needEmptyItems) or 0
    needEmptyFluids = tonumber(m.needEmptyFluids) or 0
    missionMode = true
    netHomeInbound = false
    netHomeMissionId = nil

    if currentDstFreq and launchCtrl then
      pcall(function() launchCtrl.setDstFrequency(currentDstFreq) end)

      local okV, vV = pcall(function() return launchCtrl.isValidDstFrequency() end)
      if okV and vV == false then
        lastMissionId = currentMissionId
        lastMissionResult = "REJECT"
        statusLine = "Reject: invalid DST frequency"
        netStatus("reject:bad_dst_freq")

        currentMissionId = nil
        currentOutpostId = nil
        currentDstFreq = nil
        autoStandby = true
        return
      end
    end

    -- HQ missions implicitly arm.
    armed = true
    statusLine = "Mission " .. tostring(currentMissionId)
    netStatus("cmd:startMission")

    -- Consume standby while running.
    autoStandby = false
    autoCycle()
  end

  if payload.homeInbound then
    local hm = payload.homeInbound
    if type(hm) == "table" then
      netHomeInbound = true
      netHomeMissionId = hm.missionId
    else
      netHomeInbound = true
      netHomeMissionId = nil
    end
    netStatus("net:homeInbound_received")
    netStatus("cmd:homeInbound")
  end
end

local function handlePacket(remote, pkt)
  if type(pkt) ~= "table" then return end
  if pkt.v ~= 1 then return end
  if type(pkt.msgId) ~= "string" then return end

  cleanupSeen()
  if seenMsg[pkt.msgId] then
    -- Always ack duplicates so sender can stop retrying.
    if pkt.kind ~= "ACK" then netAck(remote, pkt.msgId) end
    return
  end
  seenMsg[pkt.msgId] = now()

  if pkt.kind == "ACK" then
    local ack = pkt.payload and pkt.payload.ack
    if ack and ack == pendingHelloId then
      hqAddr = remote
      pendingHelloId = nil
      netStatus("hello:acked")
    end
    return
  end

  -- Ack everything else.
  netAck(remote, pkt.msgId)

  if pkt.kind == "CMD" then
    hqAddr = remote
    handleCmd(pkt.payload)
  elseif pkt.kind == "PING" then
    hqAddr = remote
    netSend(remote, {kind = "PONG", msgId = msgId(), payload = {state = getState()}})
  end
end

local function handleNetEvent(localAddr, remoteAddr, port, _distance, data)
  if NET_MODE == "modem" then
    if not modem or localAddr ~= modem.address then return end
    if port ~= NET_PORT then return end
  elseif NET_MODE == "tunnel" then
    if not tunnel or localAddr ~= tunnel.address then return end
    -- ignore port
  else
    return
  end
  if type(data) ~= "string" then return end
  local ok, pkt = pcall(serialization.unserialize, data)
  if not ok then return end
  handlePacket(remoteAddr, pkt)
end

local function setBundledOut(color, value)
  rs.setBundledOutput(SIDE, color, value)
end

local function applyDoor()
  -- inverted: red ON=closed, red OFF=open
  setBundledOut(CH_DOOR, doorOpen and OFF or ON)
end

local function applyLights()
  setBundledOut(CH_LIGHTS, lightsOn and ON or OFF)
end

local function applyAlarm()
  setBundledOut(CH_ALARM, alarmOn and ON or OFF)
end

local function isItemCell(st)
  if not st then return false end
  local name = st.name or ""
  if type(name) ~= "string" then name = "" end
  if name:find("appliedenergistics2", 1, true) and name:find("StorageCell", 1, true) then
    return true
  end
  local label = st.label or ""
  if type(label) == "string" and label:find("ME Storage Cell", 1, true) and (not label:find("Multi-Fluid", 1, true)) then
    return true
  end
  return false
end

local function isFluidCell(st)
  if not st then return false end
  local name = st.name or ""
  if type(name) ~= "string" then name = "" end
  if name:find("ae2fc:", 1, true) and name:find("multi_fluid_storage", 1, true) then
    return true
  end
  local label = st.label or ""
  if type(label) == "string" and label:find("Multi-Fluid Storage Cell", 1, true) then
    return true
  end
  return false
end

local function detectLoaderInvSide()
  if loaderInvSide ~= nil then return true end
  if not transposer then return false end
  for side = 0, 5 do
    local okN, nm = pcall(function() return transposer.getInventoryName(side) end)
    local okS, sz = pcall(function() return transposer.getInventorySize(side) end)
    if okN and okS and nm == "tile.cargo" and type(sz) == "number" then
      loaderInvSide = side
      return true
    end
  end
  return false
end

local function countStagingCells()
  if not detectLoaderInvSide() then return nil, nil, "no tile.cargo" end
  local okSz, sz = pcall(function() return transposer.getInventorySize(loaderInvSide) end)
  if not okSz or type(sz) ~= "number" then return nil, nil, "no inv" end
  local items, fluids, other = 0, 0, 0
  for slot = 1, sz do
    local st = transposer.getStackInSlot(loaderInvSide, slot)
    if st then
      local n = tonumber(st.size) or 0
      if isItemCell(st) then items = items + n
      elseif isFluidCell(st) then fluids = fluids + n
      else other = other + n end
    end
  end
  return items, fluids, other
end

local function stagingIsEmpty()
  local it, fl, other = countStagingCells()
  if it == nil then return false end
  return (it + fl + other) == 0
end

local function findCraftables()
  if not me then return false end
  if craftEmptyCell and craftEmptyFluid then return true end
  local ok, list = pcall(function() return me.getCraftables() end)
  if not ok or type(list) ~= "table" then return false end
  for _, c in ipairs(list) do
    local okS, s = pcall(function() return c.getItemStack() end)
    if okS and type(s) == "table" and type(s.label) == "string" then
      if (not craftEmptyCell) and s.label:find("EMPTYCELL", 1, true) then craftEmptyCell = c end
      if (not craftEmptyFluid) and s.label:find("EMPTYFLUID", 1, true) then craftEmptyFluid = c end
    end
  end
  return craftEmptyCell ~= nil and craftEmptyFluid ~= nil
end

local function safeSetEnabled(dev, on)
  if not dev then return end
  pcall(function() dev.setEnabled(on) end)
end

local function safeIsEnabled(dev)
  if not dev then return false end
  local ok, v = pcall(function() return dev.isEnabled() end)
  return ok and v or false
end

isDocked = function()
  if not launchCtrl then return false end
  local ok, v = pcall(function() return launchCtrl.isRocketDocked() end)
  return ok and v or false
end

local function homeSignalBlue()
  if rs.getBundledInput then
    local ok, v = pcall(function() return rs.getBundledInput(SIDE, CH_HOME) end)
    if ok and type(v) == "number" then return v > 0 end
  end
  return false
end

local function readUnloaderStatus()
  if not unloader then return nil, "MISSING" end
  local ok, success, st = pcall(function() return unloader.getInvStatus() end)
  if not ok then return nil, "ERROR" end
  return success, st
end

local function readLoaderStatus()
  if not loader then return nil, "MISSING" end
  local ok, success, st = pcall(function() return loader.getStatus() end)
  if not ok then return nil, "ERROR" end
  return success, st
end

------------------------------------------------
-- UI
------------------------------------------------
local function draw(msg)
  term.clear()
  print("ROCKET SILO CONTROL")
  print("Bundled side: EAST")
  print("")
  print("Keys: 1-6 | 5 auto standby | A abort | Q quit")
  print("------------------------------------------")
  print(string.format("1) Door              %s", doorOpen and "[OPEN]" or "[CLOSED]"))
  print(string.format("2) Lights            %s", lightsOn and "[ON]" or "[OFF]"))
  print(string.format("3) Launch Controller %s",
    launchCtrl and (safeIsEnabled(launchCtrl) and "[ENABLED]" or "[DISABLED]") or "[MISSING]"))
  print(string.format("4) Alarm             %s", alarmOn and "[ON]" or "[OFF]"))
  local autoStr
  if busy then autoStr = "[RUNNING]"
  elseif autoStandby then autoStr = "[WAITING]"
  else autoStr = "[OFF]" end
  print(string.format("5) AUTO              %s", autoStr))
  print(string.format("6) ARM / DISARM      %s", armed and "[ARMED]" or "[DISARMED]"))
  print("------------------------------------------")
  print("Rocket docked: " .. (isDocked() and "YES" or "NO"))
  print("Home (BLUE):   " .. (homeSignalBlue() and "ON" or "OFF"))
  if missionMode then
    print("Mission needs empties: items=" .. tostring(needEmptyItems) .. " fluids=" .. tostring(needEmptyFluids))
  end

  local us, ust = readUnloaderStatus()
  local ls, lst = readLoaderStatus()

  print("Unloader: " .. (unloader and (safeIsEnabled(unloader) and "ON" or "OFF") or "MISSING") ..
        " | last=" .. tostring(ust))
  print("Loader:   " .. (loader and (safeIsEnabled(loader) and "ON" or "OFF") or "MISSING") ..
        " | last=" .. tostring(lst))

  print("------------------------------------------")
  print("Status: " .. (msg or statusLine))
  if busy then print("NOTE: AUTO running. Press A to abort.") end
end

local function pollKey(timeout)
  if abortRequested then return "abort" end
  local deadline = now() + (timeout or 0)
  while true do
    if abortRequested then return "abort" end
    local remaining = deadline - now()
    if remaining <= 0 then return end
    local ev, a1, a2, a3, a4, a5 = event.pull(remaining)
    if ev == nil then return end
    if ev == "key_down" then
      local ch = a2
      if ch == string.byte("a") or ch == string.byte("A") then return "abort" end
      if ch == string.byte("q") or ch == string.byte("Q") then return "quit" end
    elseif ev == "modem_message" then
      -- signature: localAddress, remoteAddress, port, distance, ...
      handleNetEvent(a1, a2, a3, a4, a5)
    end
    maybeHeartbeat()
  end
end

------------------------------------------------
-- Abort / Cleanup
------------------------------------------------
abortAuto = function()
  busy = false
  abortRequested = false
  alarmOn = false; applyAlarm()

  -- leave door OPEN (safe, and matches your earlier behavior)
  doorOpen = true; applyDoor()
  lightsOn = true; applyLights()

  safeSetEnabled(unloader, false)
  safeSetEnabled(loader, false)
  safeSetEnabled(launchCtrl, false)

  statusLine = "ABORTED"

  -- If we were in a mission, report abort with mission id.
  if currentMissionId then
    lastMissionId = currentMissionId
    lastMissionResult = "ABORT"
    autoStandby = true
    statusLine = "ABORTED (awaiting orders)"
  end

  netStatus("auto:aborted")

  -- Clear mission after reporting.
  if currentMissionId then
    currentMissionId = nil
    currentOutpostId = nil
    currentDstFreq = nil
    needEmptyItems = 0
    needEmptyFluids = 0
    missionMode = false
  end
  draw(statusLine)
end

------------------------------------------------
-- Launch logic
------------------------------------------------
local function triggerLaunch()
  if not launchCtrl then
    statusLine = "No launch controller!"
    return false
  end

  -- Enable and hold
  safeSetEnabled(launchCtrl, false)
  os.sleep(0.2)
  safeSetEnabled(launchCtrl, true)

  local holdEnd = computer.uptime() + LAUNCH_ENABLE_HOLD
  while computer.uptime() < holdEnd do
    draw("Launching... (holding enable)")
    if pollKey(1) == "abort" then return false end
    maybeHeartbeat()
  end

  -- Confirm undock
  local start = computer.uptime()
  local falseCount = 0
  while computer.uptime() - start < LAUNCH_CONFIRM_TIMEOUT do
    if not isDocked() then
      falseCount = falseCount + 1
    else
      falseCount = 0
    end

    draw("Confirm depart " .. falseCount .. "/" .. DOCKED_FALSE_CONFIRM)
    if falseCount >= DOCKED_FALSE_CONFIRM then break end
    if pollKey(LAUNCH_POLL) == "abort" then return false end
    maybeHeartbeat()
  end

  -- Disable after confirmed / timeout
  safeSetEnabled(launchCtrl, false)
  return not isDocked()
end

------------------------------------------------
-- Unload until empty
------------------------------------------------
local function unloadUntilEmpty()
  if not unloader then
    draw("No cargo_unloader; skipping unload.")
    return true
  end

  -- Interlock
  safeSetEnabled(loader, false)
  safeSetEnabled(unloader, true)

  -- Let it start doing work
  local endDelay = computer.uptime() + UNLOAD_ENABLE_DELAY
  while computer.uptime() < endDelay do
    draw("Unloading... (startup)")
    if pollKey(1) == "abort" then return false end
    maybeHeartbeat()
  end

  local emptyConfirm = 0
  while true do
    local _, st = readUnloaderStatus()
    draw("Unloading... last=" .. tostring(st) .. " empty=" .. emptyConfirm .. "/" .. UNLOAD_EMPTY_CONFIRM)

    if st == "TARGET_EMPTY" then
      emptyConfirm = emptyConfirm + 1
    else
      emptyConfirm = 0
    end

    if st == "TARGET_NOT_FOUND" then
      draw("ERROR: Unloader target not found.")
      safeSetEnabled(unloader, false)
      return false
    end

    if emptyConfirm >= UNLOAD_EMPTY_CONFIRM then
      break
    end

    local k = pollKey(STATUS_POLL)
    if k == "abort" then safeSetEnabled(unloader, false) return false end
    maybeHeartbeat()
  end

  safeSetEnabled(unloader, false)
  return true
end

------------------------------------------------
-- Load until out of items (while docked)
------------------------------------------------
local function loadUntilOut()
  if not loader then
    draw("No cargo_loader; skipping load.")
    return true
  end

  -- Only makes sense if docked
  if not isDocked() then
    draw("Loader skipped: rocket not docked.")
    safeSetEnabled(loader, false)
    return true
  end

  -- Interlock
  safeSetEnabled(unloader, false)
  safeSetEnabled(loader, true)

  local start = computer.uptime()
  local minEnd = start + LOADER_MIN_ON_SECONDS
  local timeoutEnd = start + LOADER_TIMEOUT
  local outConfirm = 0

  while true do
    if pollKey(0) == "abort" then safeSetEnabled(loader, false) return false end

    local _, st = readLoaderStatus()
    local dock = isDocked()
    local now = computer.uptime()

    if st == "OUT_OF_ITEMS" then
      outConfirm = outConfirm + 1
    else
      outConfirm = 0
    end

    draw("Loading... last=" .. tostring(st) ..
         " out=" .. outConfirm .. "/" .. LOADER_OUT_CONFIRM ..
         " dock=" .. (dock and "YES" or "NO"))

    if st == "TARGET_NOT_FOUND" then
      draw("ERROR: Loader target not found.")
      safeSetEnabled(loader, false)
      return false
    end

    -- Always keep on for at least min time
    if now < minEnd then
      local k = pollKey(STATUS_POLL)
      if k == "abort" then safeSetEnabled(loader, false) return false end
      maybeHeartbeat()
    else
      -- After min time: stop if we're out of items, or if rocket left
      if (outConfirm >= LOADER_OUT_CONFIRM) or (not dock) then
        break
      end
      if now >= timeoutEnd then
        draw("Loader timeout reached; stopping.")
        break
      end
      local k = pollKey(STATUS_POLL)
      if k == "abort" then safeSetEnabled(loader, false) return false end
      maybeHeartbeat()
    end
  end

  safeSetEnabled(loader, false)
  return true
end

local function rejectMission(reason)
  lastMissionId = currentMissionId
  lastMissionResult = "REJECT"
  statusLine = reason
  netStatus(reason)

  safeSetEnabled(loader, false)
  safeSetEnabled(unloader, false)

  busy = false
  autoStandby = true
  currentMissionId = nil
  currentOutpostId = nil
  currentDstFreq = nil
  needEmptyItems = 0
  needEmptyFluids = 0
  missionMode = false
end

local function preflightStageAndLoadEmpties()
  if not isDocked() then
    rejectMission("reject:rocket_not_docked")
    return false
  end
  if not loader then
    rejectMission("reject:no_loader")
    return false
  end
  if not transposer then
    rejectMission("reject:no_transposer")
    return false
  end
  if not detectLoaderInvSide() then
    rejectMission("reject:no_tile_cargo")
    return false
  end
  if not stagingIsEmpty() then
    rejectMission("reject:staging_dirty")
    return false
  end
  if not me then
    rejectMission("reject:no_me")
    return false
  end
  if not findCraftables() then
    rejectMission("reject:no_craftables")
    return false
  end

  netStatus("preflight:craft_requested")
  local rCell = nil
  local rFluid = nil
  if needEmptyItems > 0 then
    local ok, r = pcall(function() return craftEmptyCell.request(needEmptyItems, true) end)
    if not ok or not r then
      rejectMission("reject:ae2_request_failed")
      return false
    end
    rCell = r
  end
  if needEmptyFluids > 0 then
    local ok, r = pcall(function() return craftEmptyFluid.request(needEmptyFluids, true) end)
    if not ok or not r then
      rejectMission("reject:ae2_request_failed")
      return false
    end
    rFluid = r
  end

  if needEmptyItems == 0 and needEmptyFluids == 0 then
    -- Nothing to stage.
    return true
  end

  -- Wait for staging inventory to contain exact counts.
  local start = now()
  while now() - start < PREFLIGHT_TIMEOUT do
    if pollKey(0) == "abort" then abortAuto(); return false end

    if rCell and (rCell.isCanceled and rCell.isCanceled()) then
      rejectMission("reject:ae2_canceled")
      return false
    end
    if rFluid and (rFluid.isCanceled and rFluid.isCanceled()) then
      rejectMission("reject:ae2_canceled")
      return false
    end

    local it, fl, other = countStagingCells()
    if it and fl and other then
      if other > 0 then
        rejectMission("reject:staging_unexpected")
        return false
      end
      if it == needEmptyItems and fl == needEmptyFluids then
        netStatus("preflight:staging_ready")
        break
      end
    end
    maybeHeartbeat()
    os.sleep(PREFLIGHT_POLL)
  end

  local it2, fl2, other2 = countStagingCells()
  if not it2 or not fl2 or other2 ~= 0 or it2 ~= needEmptyItems or fl2 ~= needEmptyFluids then
    rejectMission("reject:ae2_timeout")
    return false
  end

  -- Load empties into rocket.
  safeSetEnabled(loader, false)
  os.sleep(0.2)
  safeSetEnabled(loader, true)
  local loadStart = now()
  local emptyConfirm = 0
  while now() - loadStart < 180 do
    if pollKey(0) == "abort" then safeSetEnabled(loader, false) abortAuto(); return false end

    local it, fl, other = countStagingCells()
    if it and fl and other and (it + fl + other) == 0 then
      emptyConfirm = emptyConfirm + 1
      if emptyConfirm >= 3 then
        safeSetEnabled(loader, false)
        netStatus("preflight:loaded_empties")
        return true
      end
    else
      emptyConfirm = 0
    end

    local ok, success, st = pcall(function() return loader.getStatus() end)
    if ok and success and (st == "TARGET_FULL" or st == "TARGET_NOT_FOUND" or st == "TARGET_LACKS_INVENTORY") then
      safeSetEnabled(loader, false)
      rejectMission("reject:loader_" .. tostring(st))
      return false
    end
    maybeHeartbeat()
    os.sleep(1)
  end
  safeSetEnabled(loader, false)
  rejectMission("reject:loader_timeout")
  return false
end

------------------------------------------------
-- AUTO
------------------------------------------------
autoCycle = function()
  if busy then return end
  if not armed then
    draw("AUTO locked: arm first (6).")
    return
  end
  busy = true
  abortRequested = false
  netStatus("auto:start")

  -- Mission preflight: stage and load empty replacement cells before launch.
  if missionMode and ((needEmptyItems > 0) or (needEmptyFluids > 0)) then
    draw("Mission: Preflight empties...")
    if not preflightStageAndLoadEmpties() then
      -- preflight function handles reject/abort
      return
    end
  end

  -- Start alarm for launch phase
  alarmOn = true; applyAlarm()

  -- Door open
  doorOpen = true; applyDoor()
  for i=DOOR_OPEN_SETTLE,1,-1 do
    draw("AUTO: Door opening ("..i.."s)")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end

  -- Lights off
  lightsOn = false; applyLights()
  for i=PRE_LAUNCH_DELAY,1,-1 do
    draw("AUTO: Pre-launch ("..i.."s)")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end

  -- Launch
  draw("AUTO: Launching...")
  if not triggerLaunch() then abortAuto(); return end

  -- Keep alarm a bit after liftoff
  for i=ALARM_TAKEOFF_EXTRA,1,-1 do
    draw("AUTO: Takeoff ("..i.."s)")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end
  alarmOn = false; applyAlarm()

  -- Wait then close door
  for i=AFTER_LAUNCH_WAIT,1,-1 do
    draw("AUTO: Post-launch wait ("..i.."s)")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end
  doorOpen = false; applyDoor()
  draw("AUTO: Door closed.")

  -- Wait for HOME: BLUE wire (manual fallback) OR network signal from HQ/outpost.
  while true do
    local homeNet = netHomeInbound and ((not netHomeMissionId) or (netHomeMissionId == currentMissionId))
    if isDocked() or homeSignalBlue() or homeNet then
      break
    end
    draw("AUTO: Waiting HOME (BLUE/NET)...")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end

  -- Open door for arrival
  doorOpen = true; applyDoor()
  -- consume network home flag for this mission
  netHomeInbound = false
  netHomeMissionId = nil
  draw("AUTO: HOME received, door open.")

  -- Wait for dock
  while not isDocked() do
    draw("AUTO: Waiting for rocket to dock...")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end

  -- Close door, lights on
  doorOpen = false; applyDoor()
  for i=AFTER_LANDING_LIGHTS_DELAY,1,-1 do
    draw("AUTO: Landing settle ("..i.."s)")
    if pollKey(1) == "abort" then abortAuto(); return end
    maybeHeartbeat()
  end
  lightsOn = true; applyLights()

  -- NEW: Unload + Load using Galacticraft status calls
  draw("AUTO: Unloading cargo...")
  if not unloadUntilEmpty() then abortAuto(); return end

  if not missionMode then
    draw("AUTO: Loading return cargo...")
    if not loadUntilOut() then abortAuto(); return end
  end

  busy = false
  if missionMode then
    lastMissionId = currentMissionId
    lastMissionResult = "DONE"
    netStatus("mission:done")
    currentMissionId = nil
    currentOutpostId = nil
    currentDstFreq = nil
    needEmptyItems = 0
    needEmptyFluids = 0
    missionMode = false
    autoStandby = true
    statusLine = "Awaiting orders"
    netStatus("auto:complete")
  else
    statusLine = "AUTO complete"
    netStatus("auto:complete")
  end
  draw(statusLine)
end

------------------------------------------------
-- MAIN
------------------------------------------------
-- Safe startup state
pcall(function()
  local up = dofile("/home/updater.lua")
  if up and up.run then up.run({manifestUrl = UPDATE_MANIFEST_URL, currentVersion = SCRIPT_VERSION, target = "silo"}) end
end)

doorOpen = true
lightsOn = false
alarmOn = false
applyDoor(); applyLights(); applyAlarm()
safeSetEnabled(unloader, false)
safeSetEnabled(loader, false)
safeSetEnabled(launchCtrl, false)

if NET_MODE == "modem" and modem then
  modem.open(NET_PORT)
elseif NET_FORCE_MODE == "modem" then
  -- Intended setup requires a network card.
  statusLine = "ERROR: No modem/network card"
end

-- Seed PRNG for message IDs
math.randomseed(math.floor(computer.uptime() * 1000000) % 2147483647)

draw("Ready")

netHello(true)

while true do
  maybeHeartbeat()
  local ev, a1, a2, a3, a4, a5 = event.pull(0.2)
  if ev == "modem_message" then
    handleNetEvent(a1, a2, a3, a4, a5)
    draw()
  end
  if ev ~= "key_down" then
    goto continue
  end

  local ch = a2

  if ch == string.byte("q") or ch == string.byte("Q") then
    break
  elseif ch == string.byte("a") or ch == string.byte("A") then
    abortAuto()
  elseif ch == string.byte("1") then
    if not busy then doorOpen = not doorOpen; applyDoor() end
  elseif ch == string.byte("2") then
    if not busy then lightsOn = not lightsOn; applyLights() end
  elseif ch == string.byte("3") then
    if not busy and launchCtrl then safeSetEnabled(launchCtrl, not safeIsEnabled(launchCtrl)) end
  elseif ch == string.byte("4") then
    if not busy then alarmOn = not alarmOn; applyAlarm() end
  elseif ch == string.byte("6") then
    if not busy then armed = not armed end
  elseif ch == string.byte("5") then
    if not busy then
      autoStandby = not autoStandby
      statusLine = autoStandby and "Awaiting orders" or "Manual mode"
      netStatus("local:autoToggle")
    end
  end

  draw()

  ::continue::
end

abortAuto()
term.clear()
print("Closed.")
