-- Moon Outpost Controller
-- Requests pickup when enough full AE2 cells are buffered in the cargo loader.
-- Uses transposer to read cargo loader inventory (tile.cargo) and components to control
-- cargo_loader/cargo_unloader/launch controller.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local os = require("os")
local serialization = require("serialization")
local term = require("term")

local SCRIPT_VERSION = "0.2.6"
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

------------------------------------------------
-- CONFIG
------------------------------------------------
local OUTPOST_ID = "OUTPOST_01"
local PLANET_NAME = "Unknown"
-- Source pad frequency is set in-world; script reads it from cargo_launch_controller.

-- If you have more than one launch controller nearby, set this to the component address.
local LAUNCH_CTRL_ADDR = nil

-- Optional: pin a specific transposer if more than one.
local TRANSPOSER_ADDR = nil

-- Optional: force which transposer side is the cargo loader inventory.
-- If nil, auto-detect by inventory name "tile.cargo".
local LOADER_INV_SIDE = nil

-- Auto request threshold
local DRIVE_THRESHOLD = 6

-- Detection / debounce
-- Slow polling is fine; drives arrive gradually.
local DETECT_PERIOD = 60.0
local DETECT_CONFIRM = 1

-- Apply config overrides
if type(CFG.OUTPOST_ID) == "string" and CFG.OUTPOST_ID ~= "" then OUTPOST_ID = CFG.OUTPOST_ID end
if type(CFG.PLANET_NAME) == "string" and CFG.PLANET_NAME ~= "" then PLANET_NAME = CFG.PLANET_NAME end
if type(CFG.LAUNCH_CTRL_ADDR) == "string" and CFG.LAUNCH_CTRL_ADDR ~= "" then LAUNCH_CTRL_ADDR = CFG.LAUNCH_CTRL_ADDR end
if type(CFG.TRANSPOSER_ADDR) == "string" and CFG.TRANSPOSER_ADDR ~= "" then TRANSPOSER_ADDR = CFG.TRANSPOSER_ADDR end
if type(CFG.LOADER_INV_SIDE) == "number" then LOADER_INV_SIDE = CFG.LOADER_INV_SIDE end
if type(CFG.DRIVE_THRESHOLD) == "number" then DRIVE_THRESHOLD = CFG.DRIVE_THRESHOLD end
if type(CFG.DETECT_PERIOD) == "number" then DETECT_PERIOD = CFG.DETECT_PERIOD end

local NET_PORT = 4242
local HELLO_PERIOD = 5.0
local PICKUP_RETRY_PERIOD = 5.0
local STATUS_ACTIVE_PERIOD = 5.0
local HOME_RETRY_PERIOD = 5.0
local HOME_RETRY_MAX_SECONDS = 120.0

-- Cargo operation tuning
local UNLOAD_TIMEOUT = 90.0
local LOAD_TIMEOUT = 300.0
local DOCK_SETTLE_SECONDS = 2.0
local RETRY_BACKOFF_SECONDS = 10.0

-- Blocked handling
local BLOCKED_RECALL_SECONDS = 600.0 -- auto recall after 10 minutes from first unload attempt

-- Apply config overrides (timing)
if type(CFG.UNLOAD_TIMEOUT) == "number" then UNLOAD_TIMEOUT = CFG.UNLOAD_TIMEOUT end
if type(CFG.BLOCKED_RECALL_SECONDS) == "number" then BLOCKED_RECALL_SECONDS = CFG.BLOCKED_RECALL_SECONDS end

------------------------------------------------
-- COMPONENTS
------------------------------------------------
local modem = component.isAvailable("modem") and component.modem or nil
local launchCtrl = nil
local launchCtrlAddr = nil
local cargoLoader = component.isAvailable("cargo_loader") and component.cargo_loader or nil
local cargoUnloader = component.isAvailable("cargo_unloader") and component.cargo_unloader or nil
local transposer = nil
local transposerAddr = nil

local function pickLaunchController()
  if LAUNCH_CTRL_ADDR and component.type(LAUNCH_CTRL_ADDR) == "cargo_launch_controller" then
    launchCtrlAddr = LAUNCH_CTRL_ADDR
    launchCtrl = component.proxy(LAUNCH_CTRL_ADDR)
    return
  end

  if component.isAvailable("cargo_launch_controller") then
    -- primary, if present
    launchCtrl = component.cargo_launch_controller
    -- best-effort address lookup
    for addr in component.list("cargo_launch_controller") do
      launchCtrlAddr = addr
      break
    end
    return
  end

  for addr in component.list("cargo_launch_controller") do
    launchCtrlAddr = addr
    launchCtrl = component.proxy(addr)
    return
  end
end

pickLaunchController()

local function pickTransposer()
  if TRANSPOSER_ADDR and component.type(TRANSPOSER_ADDR) == "transposer" then
    transposerAddr = TRANSPOSER_ADDR
    transposer = component.proxy(TRANSPOSER_ADDR)
    return
  end
  for addr in component.list("transposer") do
    transposerAddr = addr
    transposer = component.proxy(addr)
    return
  end
end

pickTransposer()

if not modem then
  error("No modem found. Install a network card.")
end

if not launchCtrl then
  error("No cargo_launch_controller found.")
end

if not cargoLoader then
  error("No cargo_loader found.")
end

if not cargoUnloader then
  error("No cargo_unloader found.")
end

if not transposer then
  error("No transposer found.")
end

------------------------------------------------
-- STATE
------------------------------------------------
local hqAddr = nil
local lastHelloAt = 0
local statusLine = "Ready"

local lastFreqPollAt = 0
local cachedPadFreq = nil
local cachedPadFreqValid = nil
local cachedDstFreq = nil
local cachedDstFreqValid = nil
local lastFreqErr = nil

local loaderSide = nil
local lastDetectAt = 0
local detectHits = 0
local lastItemCells = 0
local lastFluidCells = 0

-- Mission state
local requestPending = false
local requestManual = false
local currentMissionId = nil
local lastMissionId = nil
local returnFreq = nil
local missionStage = "IDLE" -- IDLE, REQUESTED, WAIT_DOCK, UNLOADING, LOADING, LAUNCHING_HOME
local lastDocked = false
local lastPickupSendAt = 0
local lastStatusAt = 0

local homePending = false
local lastHomeSendAt = 0
local homeFirstSendAt = 0
local lastHomeMsgId = nil
local recentHomeMsgIds = {}
local lastHomeExtra = nil

local missionProcessing = false
local missionNextAttemptAt = 0

local blockedSince = 0
local blockedReason = nil
local suspended = false

local function now() return computer.uptime() end

local function resetBlockedState()
  blockedSince = 0
  blockedReason = nil
end

local function recordFirstUnloadAttempt()
  if blockedSince == 0 then
    blockedSince = now()
  end
end

local function homeMsgIdRemember(id)
  if type(id) ~= "string" or id == "" then return end
  recentHomeMsgIds[#recentHomeMsgIds + 1] = id
  if #recentHomeMsgIds > 5 then
    table.remove(recentHomeMsgIds, 1)
  end
end

local function homeMsgIdMatches(id)
  if not id then return false end
  if lastHomeMsgId and id == lastHomeMsgId then return true end
  for _, v in ipairs(recentHomeMsgIds) do
    if v == id then return true end
  end
  return false
end

local function msgId()
  return tostring(math.floor(now() * 1000)) .. "-" .. tostring(math.random(100000, 999999))
end

local function safeSetEnabled(comp, enable)
  if not comp then return false end
  local ok, v = pcall(function() return comp.setEnabled(enable) end)
  return ok and v or false
end

local function safeIsEnabled(comp)
  if not comp then return false end
  local ok, v = pcall(function() return comp.isEnabled() end)
  return ok and v or false
end

local function getInvName(side)
  local ok, v = pcall(function() return transposer.getInventoryName(side) end)
  if ok then return v end
end

local function getInvSize(side)
  local ok, v = pcall(function() return transposer.getInventorySize(side) end)
  if ok then return v end
end

local function isItemCell(st)
  local name = st and st.name or ""
  if type(name) ~= "string" then name = "" end
  if name:find("appliedenergistics2", 1, true) and (name:find("StorageCell", 1, true) or name:find("ItemBasicStorageCell", 1, true) or name:find("ItemAdvancedStorageCell", 1, true)) then
    return true
  end
  local label = st and st.label or ""
  if type(label) == "string" and label:find("ME Storage Cell", 1, true) and (not label:find("Multi-Fluid", 1, true)) then
    return true
  end
  return false
end

local function isFluidCell(st)
  local name = st and st.name or ""
  if type(name) ~= "string" then name = "" end
  if name:find("ae2fc:", 1, true) and name:find("multi_fluid_storage", 1, true) then
    return true
  end
  local label = st and st.label or ""
  if type(label) == "string" and label:find("Multi-Fluid Storage Cell", 1, true) then
    return true
  end
  return false
end

local function detectLoaderSide()
  if LOADER_INV_SIDE ~= nil then
    loaderSide = LOADER_INV_SIDE
    return true
  end
  if loaderSide ~= nil then return true end

  local bestSide = nil
  local bestScore = -1
  for side = 0, 5 do
    local sz = getInvSize(side)
    if sz and sz > 0 then
      local nm = getInvName(side)
      if nm == "tile.cargo" then
        local score = 0
        for slot = 1, math.min(sz, 15) do
          local st = transposer.getStackInSlot(side, slot)
          if st and (isItemCell(st) or isFluidCell(st)) then
            score = score + 1
          end
        end
        if score > bestScore then
          bestScore = score
          bestSide = side
        end
      end
    end
  end

  if bestSide ~= nil then
    loaderSide = bestSide
    return true
  end
  return false
end

local function countCells()
  if not detectLoaderSide() then
    return nil, nil, "no tile.cargo found"
  end
  local sz = getInvSize(loaderSide)
  if not sz then
    return nil, nil, "no inventory on loader side"
  end
  local items, fluids = 0, 0
  for slot = 1, sz do
    local st = transposer.getStackInSlot(loaderSide, slot)
    if st then
      local n = tonumber(st.size) or 0
      if isItemCell(st) then items = items + n
      elseif isFluidCell(st) then fluids = fluids + n
      end
    end
  end
  return items, fluids
end

local function pollFreq()
  if not launchCtrl then return end
  if now() - lastFreqPollAt < 1.0 then return end
  lastFreqPollAt = now()
  lastFreqErr = nil

  local ok1, v1 = pcall(function() return launchCtrl.getFrequency() end)
  if ok1 then cachedPadFreq = v1 else lastFreqErr = tostring(v1) end
  local ok2, v2 = pcall(function() return launchCtrl.isValidFrequency() end)
  if ok2 then cachedPadFreqValid = v2 else lastFreqErr = tostring(v2) end
  local ok3, v3 = pcall(function() return launchCtrl.getDstFrequency() end)
  if ok3 then cachedDstFreq = v3 else lastFreqErr = tostring(v3) end
  local ok4, v4 = pcall(function() return launchCtrl.isValidDstFrequency() end)
  if ok4 then cachedDstFreqValid = v4 else lastFreqErr = tostring(v4) end
end

local function isDocked()
  if not launchCtrl then return false end
  local ok, v = pcall(function() return launchCtrl.isRocketDocked() end)
  return ok and v or false
end

local function sendPkt(addr, pkt)
  pkt.v = 1
  pkt.from = OUTPOST_ID
  pkt.ts = now()
  local s = serialization.serialize(pkt)
  return modem.send(addr, NET_PORT, s)
end

local function broadcast(pkt)
  pkt.v = 1
  pkt.from = OUTPOST_ID
  pkt.ts = now()
  local s = serialization.serialize(pkt)
  return modem.broadcast(NET_PORT, s)
end

local function ack(addr, ackMsgId)
  sendPkt(addr, {kind = "ACK", msgId = msgId(), payload = {ack = ackMsgId}})
end

local function hello(force)
  if (not force) and (now() - lastHelloAt < HELLO_PERIOD) then return end
  pollFreq()
  broadcast({
    kind = "HELLO",
    msgId = msgId(),
    to = "HQ",
    payload = {
      role = "outpost",
      outpostId = OUTPOST_ID,
      info = {planetName = PLANET_NAME, padFreq = cachedPadFreq, padFreqValid = cachedPadFreqValid},
      caps = {launch = launchCtrl ~= nil, load = cargoLoader ~= nil, unload = cargoUnloader ~= nil, transposer = transposer ~= nil},
      state = {
        outpostId = OUTPOST_ID,
        docked = isDocked(),
        statusLine = statusLine,
        stage = missionStage,
        missionId = currentMissionId,
        blockedReason = blockedReason,
        blockedSince = blockedSince,
        suspended = suspended,
        padFreq = cachedPadFreq,
        padFreqValid = cachedPadFreqValid,
        dstFreqCtrl = cachedDstFreq,
        dstFreqValid = cachedDstFreqValid,
        loaderSide = loaderSide,
      },
    }
  })
  lastHelloAt = now()
end

local function status(reason)
  pollFreq()
  local ic, fc = countCells()
  broadcast({
    kind = "STATUS",
    msgId = msgId(),
    to = "HQ",
    payload = {
      reason = reason,
      state = {
        outpostId = OUTPOST_ID,
        docked = isDocked(),
        statusLine = statusLine,
        stage = missionStage,
        missionId = currentMissionId,
        blockedReason = blockedReason,
        blockedSince = blockedSince,
        suspended = suspended,
        itemCells = ic,
        fluidCells = fc,
        padFreq = cachedPadFreq,
        padFreqValid = cachedPadFreqValid,
        dstFreqCtrl = cachedDstFreq,
        dstFreqValid = cachedDstFreqValid,
        loaderSide = loaderSide,
      }
    }
  })
  lastStatusAt = now()
end

local function requestPickup(manual)
  pollFreq()
  if suspended and not manual then return end
  if cachedPadFreqValid ~= true then
    statusLine = "Fix pad frequency first"
    requestPending = false
    missionStage = "IDLE"
    status("pickup_blocked_bad_freq")
    return
  end

  local ic, fc = countCells()
  if not manual then
    if not ic or not fc then
      statusLine = "No loader inventory"
      return
    end
    if (ic < DRIVE_THRESHOLD) and (fc < DRIVE_THRESHOLD) then
      return
    end
  end

  statusLine = manual and "Manual pickup requested" or "Pickup requested"
  requestPending = true
  requestManual = manual and true or false
  missionStage = "REQUESTED"
  currentMissionId = nil
  returnFreq = nil
  -- Force immediate send on next loop iteration.
  lastPickupSendAt = now() - PICKUP_RETRY_PERIOD
  status("pickup_requested")
end

local function sendPickupRequest()
  pollFreq()
  if not requestPending or missionStage ~= "REQUESTED" then return end
  if cachedPadFreqValid ~= true then
    statusLine = "Fix pad frequency first"
    requestPending = false
    missionStage = "IDLE"
    status("pickup_blocked_bad_freq")
    return
  end

  local ic, fc, err = countCells()
  if not requestManual then
    if not ic or not fc then
      statusLine = "No loader inventory"
      requestPending = false
      missionStage = "IDLE"
      status("pickup_blocked_no_loader")
      return
    end
    if (ic < DRIVE_THRESHOLD) and (fc < DRIVE_THRESHOLD) then
      -- condition cleared
      requestPending = false
      missionStage = "IDLE"
      statusLine = "Pickup cleared"
      status("pickup_cleared")
      return
    end
  end

  local pkt = {
    kind = "PICKUP_REQUEST",
    msgId = msgId(),
    to = "HQ",
    payload = {
      outpostId = OUTPOST_ID,
      planetName = PLANET_NAME,
      padFreq = cachedPadFreq,
      padFreqValid = cachedPadFreqValid,
      manual = requestManual,
      itemCells = ic,
      fluidCells = fc,
    },
  }

  broadcast(pkt)

  lastPickupSendAt = now()
end

local function sendHomeInbound(extra)
  statusLine = "HOME_INBOUND sent"
  local mid = currentMissionId or lastMissionId

  lastHomeMsgId = msgId()
  homeMsgIdRemember(lastHomeMsgId)
  if not homePending then
    homeFirstSendAt = now()
  end
  homePending = true
  lastHomeSendAt = now()

  local payload = {outpostId = OUTPOST_ID, missionId = mid}
  if type(extra) == "table" then
    lastHomeExtra = extra
  end
  if type(lastHomeExtra) == "table" then
    for k, v in pairs(lastHomeExtra) do payload[k] = v end
  end
  broadcast({kind = "HOME_INBOUND", msgId = lastHomeMsgId, to = "HQ", payload = payload})
end

local function triggerLaunchHome()
  if not launchCtrl then
    statusLine = "No launch controller"
    return false
  end
  if not returnFreq then
    statusLine = "No return frequency"
    return false
  end

  pcall(function() launchCtrl.setDstFrequency(returnFreq) end)

  local okV, vV = pcall(function() return launchCtrl.isValidDstFrequency() end)
  if okV and vV == false then
    statusLine = "Invalid return frequency"
    return false
  end

  -- Enable launch controller briefly to trigger launch.
  pcall(function() launchCtrl.setEnabled(false) end)
  os.sleep(0.2)
  pcall(function() launchCtrl.setEnabled(true) end)

  local holdEnd = now() + 8
  while now() < holdEnd do
    os.sleep(0.2)
  end
  pcall(function() launchCtrl.setEnabled(false) end)

  -- Confirm undock
  local start = now()
  while now() - start < 60 do
    if not isDocked() then
      return true
    end
    os.sleep(0.5)
  end
  return not isDocked()
end

local function unloadRocket()
  statusLine = "Unloading rocket"
  missionStage = "UNLOADING"
  status("unloading")

  safeSetEnabled(cargoUnloader, false)
  os.sleep(0.2)
  safeSetEnabled(cargoUnloader, true)

  local emptyConfirm = 0
  local notFoundConfirm = 0
  local start = now()
  while now() - start < UNLOAD_TIMEOUT do
    local ok, success, st = pcall(function() return cargoUnloader.getInvStatus() end)
    if ok and st == "TARGET_EMPTY" then
      emptyConfirm = emptyConfirm + 1
      notFoundConfirm = 0
      if emptyConfirm >= 3 then
        safeSetEnabled(cargoUnloader, false)
        return true, "TARGET_EMPTY"
      end
    elseif ok and st == "TARGET_NOT_FOUND" then
      emptyConfirm = 0
      notFoundConfirm = notFoundConfirm + 1
      if notFoundConfirm >= 2 then
        safeSetEnabled(cargoUnloader, false)
        return false, "TARGET_NOT_FOUND"
      end
    elseif ok and st == "SUCCESS" then
      -- Don't reset confirm on SUCCESS noise.
    else
      emptyConfirm = 0
      notFoundConfirm = 0
    end
    os.sleep(1)
  end

  safeSetEnabled(cargoUnloader, false)
  return false, "TIMEOUT"
end

local function enterBlocked(reason)
  safeSetEnabled(cargoUnloader, false)
  safeSetEnabled(cargoLoader, false)
  missionStage = "BLOCKED_UNLOAD"
  -- blockedSince is recorded at first unload attempt; keep it.
  if blockedSince == 0 then
    blockedSince = now()
  end
  blockedReason = reason
  statusLine = "BLOCKED: " .. tostring(reason)
  status("blocked:unload")
end

local function recallRocket(reason)
  safeSetEnabled(cargoUnloader, false)
  safeSetEnabled(cargoLoader, false)
  missionStage = "RECALLING_HOME"
  statusLine = "Recalling rocket"
  status("recall:start")
  draw()

  local ok = triggerLaunchHome()
  if ok then
    sendHomeInbound({recall = true, reason = reason or blockedReason})
    status("recall:home_inbound")
    suspended = true
    missionStage = "IDLE"
    statusLine = "Suspended after recall"
    currentMissionId = nil
    returnFreq = nil
    resetBlockedState()
    status("suspended")
  else
    missionStage = "BLOCKED_UNLOAD"
    statusLine = "Recall failed"
    status("recall:failed")
  end
end

local function loadRocket()
  statusLine = "Loading rocket"
  missionStage = "LOADING"
  status("loading")

  safeSetEnabled(cargoLoader, false)
  os.sleep(0.2)
  safeSetEnabled(cargoLoader, true)

  local outConfirm = 0
  local fullConfirm = 0
  local start = now()
  local lastCount = nil
  local idle = 0
  while now() - start < LOAD_TIMEOUT do
    local ic, fc = countCells()
    local total = (ic or 0) + (fc or 0)
    if lastCount ~= nil then
      if total >= lastCount then
        idle = idle + 1
      else
        idle = 0
      end
    end
    lastCount = total

    local ok, success, st = pcall(function() return cargoLoader.getStatus() end)
    if ok and st == "OUT_OF_ITEMS" then
      outConfirm = outConfirm + 1
      if outConfirm >= 3 then
        safeSetEnabled(cargoLoader, false)
        return true, "OUT_OF_ITEMS"
      end
    elseif ok and st == "SUCCESS" then
      -- Don't reset confirm on SUCCESS noise.
    else
      outConfirm = 0
    end

    if ok and st == "TARGET_FULL" then
      fullConfirm = fullConfirm + 1
      if fullConfirm >= 3 then
        safeSetEnabled(cargoLoader, false)
        return true, "TARGET_FULL"
      end
    elseif ok and st == "SUCCESS" then
      -- Don't reset confirm on SUCCESS noise.
    else
      fullConfirm = 0
    end

    if ok and st == "TARGET_NOT_FOUND" then
      safeSetEnabled(cargoLoader, false)
      return false, "TARGET_NOT_FOUND"
    end
    if ok and st == "TARGET_LACKS_INVENTORY" then
      safeSetEnabled(cargoLoader, false)
      return false, "TARGET_LACKS_INVENTORY"
    end

    -- Stall detection
    if idle >= 20 then
      safeSetEnabled(cargoLoader, false)
      return false, "STALL"
    end

    os.sleep(1)
  end

  safeSetEnabled(cargoLoader, false)
  return false, "TIMEOUT"
end

local function draw()
  pollFreq()
  local ic, fc = countCells()
  term.clear()
  print("OUTPOST CONTROL")
  print("Outpost: " .. OUTPOST_ID .. " | " .. PLANET_NAME)
  print("LaunchCtrl: " .. (launchCtrl and (launchCtrlAddr or "(primary)") or "MISSING"))
  print("Transposer: " .. (transposerAddr or "(none)") .. " | loaderSide=" .. tostring(loaderSide))
  print("Pad freq:   " .. tostring(cachedPadFreq) .. " | valid: " .. tostring(cachedPadFreqValid))
  print("Dst freq:   " .. tostring(cachedDstFreq) .. " | valid: " .. tostring(cachedDstFreqValid))
  if lastFreqErr then print("Freq err:   " .. tostring(lastFreqErr)) end
  print("Docked: " .. (isDocked() and "YES" or "NO"))
  print("Cells:  items=" .. tostring(ic) .. " fluids=" .. tostring(fc) .. " (>= " .. DRIVE_THRESHOLD .. ")")
  print("Stage:  " .. missionStage .. " | mission=" .. tostring(currentMissionId) .. " | returnFreq=" .. tostring(returnFreq))
  if missionStage == "BLOCKED_UNLOAD" and blockedSince and blockedSince > 0 then
    local remain = math.max(0, math.floor(BLOCKED_RECALL_SECONDS - (now() - blockedSince)))
    print("Blocked: " .. tostring(blockedReason) .. " | auto recall in " .. tostring(remain) .. "s")
  elseif suspended then
    print("SUSPENDED: press U to unsuspend")
  end
  print("")
  if missionStage == "BLOCKED_UNLOAD" then
    print("Keys: R retry | C recall | H manual home | Q quit")
  elseif suspended then
    print("Keys: U unsuspend | Q quit")
  else
    print("Keys: F manual pickup | H manual home | Q quit")
  end
  print("------------------------------------------")
  print("Last sender: " .. (hqAddr or "(none)"))
  print("Status: " .. statusLine)
end

local function cleanupLegacyOutpostMoon()
  local path = "/home/outpost_moon.lua"
  if not filesystem.exists(path) then return end
  local ok, body = pcall(function()
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
  end)
  if not ok or type(body) ~= "string" then return end
  -- Only remove if it looks like the old wrapper.
  if body:find("dofile(\"/home/outpost.lua\")", 1, true) or body:find("dofile('/home/outpost.lua')", 1, true) then
    pcall(filesystem.remove, path)
  end
end

-- init
cleanupLegacyOutpostMoon()
pcall(function()
  local up = dofile("/home/updater.lua")
  if up and up.run then up.run({manifestUrl = UPDATE_MANIFEST_URL, currentVersion = SCRIPT_VERSION, target = "outpost"}) end
end)

modem.open(NET_PORT)
math.randomseed(math.floor(computer.uptime() * 1000000) % 2147483647)

-- Safe startup: disable loader/unloader
safeSetEnabled(cargoLoader, false)
safeSetEnabled(cargoUnloader, false)

detectLoaderSide()
hello(true)
draw()

while true do
  hello(false)
  local ev, a1, a2, a3, a4, a5 = event.pull(0.2)
  if ev == "modem_message" then
    local localAddr, remoteAddr, port, _distance, data = a1, a2, a3, a4, a5
    if localAddr ~= modem.address then
      -- ignore
    elseif port == NET_PORT and type(data) == "string" then
      local ok, pkt = pcall(serialization.unserialize, data)
      if ok and type(pkt) == "table" and pkt.v == 1 and type(pkt.msgId) == "string" then
        -- For debug display only.
        hqAddr = remoteAddr
        if pkt.kind ~= "ACK" then ack(remoteAddr, pkt.msgId) end
        if pkt.kind == "ACK" then
          -- If HQ acks our last HOME_INBOUND, stop retrying.
          local ackId = pkt.payload and pkt.payload.ack
          if homePending and ackId and homeMsgIdMatches(ackId) then
            homePending = false
            recentHomeMsgIds = {}
            lastHomeExtra = nil
            statusLine = "HOME_INBOUND acked"
          end
        elseif pkt.kind == "PING" then
          sendPkt(remoteAddr, {kind = "PONG", msgId = msgId(), payload = {state = {outpostId = OUTPOST_ID, docked = isDocked(), statusLine = statusLine}}})
        elseif pkt.kind == "CMD" then
          local pl = pkt.payload
          if type(pl) == "table" and pl.missionAssigned then
            if suspended or missionStage == "BLOCKED_UNLOAD" then
              statusLine = suspended and "Ignored mission (suspended)" or "Ignored mission (blocked)"
              status("mission_ignored")
            else
            local ma = pl.missionAssigned
            if type(ma) == "table" then
              currentMissionId = ma.missionId
              lastMissionId = currentMissionId
              returnFreq = tonumber(ma.returnFreq)
              requestPending = false
              missionStage = "WAIT_DOCK"
              statusLine = "Mission assigned"
              homePending = false
              recentHomeMsgIds = {}
              lastHomeExtra = nil
              missionProcessing = false
              missionNextAttemptAt = 0
              resetBlockedState()
              -- Force dock transition check in case it's already docked.
              lastDocked = not isDocked()
              status("mission_assigned")
            end
            end
          elseif type(pl) == "table" and pl.forcePickup then
            if suspended then
              statusLine = "Force pickup ignored (suspended)"
              status("force_pickup_ignored_suspended")
            elseif missionStage ~= "IDLE" or requestPending then
              statusLine = "Force pickup ignored (busy)"
              status("force_pickup_ignored_busy")
            else
              requestPickup(true)
              status("force_pickup_requested")
            end
          end
        else
          -- ignore
        end
      end
    end
    draw()
  elseif ev == "key_down" then
    local ch = a2
    if ch == string.byte("q") or ch == string.byte("Q") then
      break
    elseif ch == string.byte("u") or ch == string.byte("U") then
      suspended = false
      statusLine = "Unsuspended"
      resetBlockedState()
      status("unsuspend")
    elseif ch == string.byte("r") or ch == string.byte("R") then
      if missionStage == "BLOCKED_UNLOAD" then
        blockedSince = now() -- reset 10-minute recall window
        blockedReason = nil
        missionStage = "WAIT_DOCK"
        missionNextAttemptAt = 0
        statusLine = "Retry requested"
        status("retry")
      end
    elseif ch == string.byte("c") or ch == string.byte("C") then
      if missionStage == "BLOCKED_UNLOAD" then
        recallRocket("manual")
      end
    elseif ch == string.byte("f") or ch == string.byte("F") then
      if not suspended then
        requestPickup(true)
      else
        statusLine = "Suspended; press U"
      end
    elseif ch == string.byte("h") or ch == string.byte("H") then
      sendHomeInbound()
    end
    draw()
  end

  -- Retry pickup request until mission assigned.
  if requestPending and missionStage == "REQUESTED" then
    if (now() - (lastPickupSendAt or 0)) >= PICKUP_RETRY_PERIOD then
      statusLine = "Retrying pickup request"
      sendPickupRequest()
      status("pickup_retry")
      draw()
    end
  end

  -- Auto detect buffered cells and request pickup (debounced).
  if missionStage == "IDLE" and (not requestPending) and (not suspended) then
    if now() - lastDetectAt >= DETECT_PERIOD then
      lastDetectAt = now()
      local ic, fc = countCells()
      if ic and fc and ((ic >= DRIVE_THRESHOLD) or (fc >= DRIVE_THRESHOLD)) then
        detectHits = detectHits + 1
      else
        detectHits = 0
      end
      lastItemCells = ic or 0
      lastFluidCells = fc or 0
      if detectHits >= DETECT_CONFIRM then
        detectHits = 0
        requestPickup(false)
        draw()
      end
    end
  end

  -- Auto recall if blocked too long.
  if missionStage == "BLOCKED_UNLOAD" and blockedSince and blockedSince > 0 then
    if (now() - blockedSince) >= BLOCKED_RECALL_SECONDS then
      recallRocket("timeout")
      draw()
    end
  end

  -- Mission status heartbeat while active.
  if missionStage ~= "IDLE" then
    if (now() - (lastStatusAt or 0)) >= STATUS_ACTIVE_PERIOD then
      status("heartbeat")
      draw()
    end
  end

  -- Retry HOME_INBOUND broadcast for reliability.
  if homePending then
    if (now() - (homeFirstSendAt or 0)) > HOME_RETRY_MAX_SECONDS then
      homePending = false
      recentHomeMsgIds = {}
      lastHomeExtra = nil
      statusLine = "HOME_INBOUND retry timeout"
      status("home_retry_timeout")
      draw()
    elseif (now() - (lastHomeSendAt or 0)) >= HOME_RETRY_PERIOD then
      statusLine = "Retrying HOME_INBOUND"
      -- Re-broadcast using a new msgId to refresh relay queues.
      sendHomeInbound(lastHomeExtra)
      status("home_retry")
      draw()
    end
  end

  local dockNow = isDocked()
  lastDocked = dockNow

  -- Mission execution: dock -> unload -> load -> launch home
  if missionStage == "WAIT_DOCK" and dockNow and (not missionProcessing) and now() >= (missionNextAttemptAt or 0) then
    missionProcessing = true

    -- settle
    os.sleep(DOCK_SETTLE_SECONDS)

    -- unload empties from rocket into base
    recordFirstUnloadAttempt()
    local okUn, whyUn = unloadRocket()
    if okUn then
      resetBlockedState()
      local okLoad, why = loadRocket()
      if okLoad then
        missionStage = "LAUNCHING_HOME"
        statusLine = "Launching home"
        status("launching_home")
        draw()

        local ok = triggerLaunchHome()
        if ok then
          statusLine = "Launched home"
          -- Tell HQ/silo that rocket is inbound.
          sendHomeInbound()
          status("home_inbound")
          missionStage = "IDLE"
          status("idle")
          currentMissionId = nil
          returnFreq = nil
          missionNextAttemptAt = 0
          resetBlockedState()
        else
          statusLine = "Launch failed"
          status("launch_failed")
          missionStage = "WAIT_DOCK"
          missionNextAttemptAt = now() + RETRY_BACKOFF_SECONDS
        end
      else
        statusLine = "Load failed: " .. tostring(why)
        status("load_failed")
        missionStage = "WAIT_DOCK"
        missionNextAttemptAt = now() + RETRY_BACKOFF_SECONDS
      end
    else
      -- Enter blocked state; no automatic retry.
      enterBlocked(whyUn)
    end

    missionProcessing = false
    draw()
  end
end

term.clear()
print("Outpost closed.")
