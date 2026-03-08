-- Mission Control HQ (wired OC network)
-- Listens for silos broadcasting HELLO and sends remote commands.

local component = require("component")
local computer = require("computer")
local event = require("event")
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

local modem = component.isAvailable("modem") and component.modem or nil
local tunnel = component.isAvailable("tunnel") and component.tunnel or nil
if not modem and not tunnel then
  error("No modem/tunnel found. Install a network card (recommended).")
end

local NET_PORT = 4242
local NET_SEEN_TTL = 30.0
local CMD_RETRY_PERIOD = 1.0
local CMD_MAX_RETRIES = 8

local hqId = (computer.getLabel and computer.getLabel()) or nil
if not hqId or hqId == "" then
  hqId = "HQ-" .. tostring(computer.address()):sub(1, 6)
end

local function now() return computer.uptime() end

local function msgId()
  return tostring(math.floor(now() * 1000)) .. "-" .. tostring(math.random(100000, 999999))
end

local silos = {} -- addr -> {nodeId=, lastSeen=, caps=, state=}
local outposts = {} -- addr -> {nodeId=, lastSeen=, caps=, info=}
local siloOrder = {} -- stable-ish list of addrs for UI
local outpostOrder = {}
local selectedSilo = 1
local selectedOutpost = 1

local requests = {} -- outpostId -> {missionId=, padFreq=, padFreqValid=, planetName=, requestedAt=, status=, addr=, itemCells=, fluidCells=}
local missions = {} -- missionId -> {outpostId=, planetName=, outpostFreq=, returnFreq=, siloId=, siloAddr=, needEmptyItems=, needEmptyFluids=, state=, createdAt=, lastUpdateAt=, log={}}

local siloActiveMission = {} -- siloId -> missionId
local outpostActiveMission = {} -- outpostId -> missionId

local SCHED_PERIOD = 1.0
local lastSchedAt = 0

local DISPATCH_TIMEOUT = 60.0
local LONG_TIMEOUT = 3600.0
local TIMEOUT_TICK = 5.0
local lastTimeoutAt = 0

local siloEligible = {} -- siloId -> bool (for edge-trigger dispatch)

local uiStatus = "Listening..."

local seenMsg = {}
local pending = {} -- msgId -> {addr=, pkt=, nextSendAt=, retries=}

local okKb, keyboard = pcall(require, "keyboard")
if not okKb then keyboard = nil end

-- UI state
local view = "main" -- main | silo_detail | outpost_detail
local focus = "silo" -- silo | outpost
local menuIndex = 1

local function isCharKey(ch, c)
  local b = string.byte(c)
  return ch == b or ch == string.byte(string.upper(c))
end

local function isKeyCode(code, k)
  return keyboard and code == keyboard.keys[k]
end

-- Prefer modem. In the relay+linked-card setup, traffic is still modem messages.
-- Force modem for the intended topology.
local NET_FORCE_MODE = "modem"
local NET_MODE = (NET_FORCE_MODE == "modem" and modem and "modem")
  or (NET_FORCE_MODE == "tunnel" and tunnel and "tunnel")
  or (NET_FORCE_MODE == nil and (modem and "modem" or (tunnel and "tunnel") or "none"))
  or "none"

local function cleanupSeen()
  local cutoff = now() - NET_SEEN_TTL
  for k, t in pairs(seenMsg) do
    if t < cutoff then seenMsg[k] = nil end
  end
end

local function sendPkt(addr, pkt)
  pkt.v = 1
  pkt.from = pkt.from or hqId
  pkt.ts = pkt.ts or now()
  local s = serialization.serialize(pkt)
  if NET_MODE == "tunnel" then
    return tunnel.send(s)
  end
  if NET_MODE ~= "modem" then return false end
  if not addr then return false end
  return modem.send(addr, NET_PORT, s)
end

local function ack(addr, ackMsgId)
  return sendPkt(addr, {kind = "ACK", msgId = msgId(), payload = {ack = ackMsgId}})
end

local function addOrUpdateSilo(addr, payload)
  local entry = silos[addr]
  if not entry then
    entry = {}
    silos[addr] = entry
    table.insert(siloOrder, addr)
  end
  entry.lastSeen = now()
  if type(payload) == "table" then
    entry.nodeId = payload.siloId or payload.nodeId or entry.nodeId or addr
    entry.caps = payload.caps or entry.caps
    if payload.state then entry.state = payload.state end
  end
end

local function addOrUpdateOutpost(addr, payload)
  local entry = outposts[addr]
  if not entry then
    entry = {}
    outposts[addr] = entry
    table.insert(outpostOrder, addr)
  end
  entry.lastSeen = now()
  if type(payload) == "table" then
    entry.nodeId = payload.outpostId or payload.nodeId or entry.nodeId or addr
    entry.caps = payload.caps or entry.caps
    entry.info = payload.info or entry.info
    if payload.state then entry.state = payload.state end
  end
end

local function siloList()
  local list = {}
  for _, addr in ipairs(siloOrder) do
    if silos[addr] then table.insert(list, addr) end
  end
  return list
end

local function outpostList()
  local list = {}
  for _, addr in ipairs(outpostOrder) do
    if outposts[addr] then table.insert(list, addr) end
  end
  return list
end

local function findOutpostAddrById(outpostId)
  for addr, e in pairs(outposts) do
    if e and e.nodeId == outpostId then return addr end
  end
end

local function selectedAddr()
  local list = siloList()
  if #list == 0 then return nil end
  if selectedSilo < 1 then selectedSilo = 1 end
  if selectedSilo > #list then selectedSilo = #list end
  return list[selectedSilo]
end

local function selectedOutpostAddr()
  local list = outpostList()
  if #list == 0 then return nil end
  if selectedOutpost < 1 then selectedOutpost = 1 end
  if selectedOutpost > #list then selectedOutpost = #list end
  return list[selectedOutpost]
end

local function writeAt(x, y, text)
  if term.setCursor then
    term.setCursor(x, y)
    if term.write then
      term.write(text)
    else
      io.write(text)
    end
  else
    -- fallback: no cursor control
    print(text)
  end
end

local function buildHistoryLines(filterFn, limit)
  local lines = {}
  for mid, m in pairs(missions) do
    if m and m.log and filterFn(m) then
      for _, e in ipairs(m.log) do
        local t = e.t or 0
        lines[#lines + 1] = {t = t, s = string.format("%s %s", tostring(mid):sub(1, 8), tostring(e.msg))}
      end
    end
  end
  table.sort(lines, function(a, b) return a.t > b.t end)
  local out = {}
  local n = math.min(#lines, limit or 10)
  for i = 1, n do
    out[#out + 1] = lines[i].s
  end
  return out
end

local function drawMain(status)
  term.clear()
  local w, h = 80, 25
  if term.getViewport then w, h = term.getViewport() end
  local mid = math.floor(w / 2)

  writeAt(1, 1, "MISSION CONTROL HQ")
  writeAt(1, 2, "Node: " .. hqId)
  writeAt(1, 3, "Mode: " .. NET_MODE .. " | Port: " .. NET_PORT)
  writeAt(1, 4, "Keys: WASD/Arrows navigate | Enter open | Q quit")
  writeAt(1, 5, string.rep("-", w))

  local siloHdr = (focus == "silo") and "SILOS*" or "SILOS"
  local outHdr = (focus == "outpost") and "OUTPOSTS*" or "OUTPOSTS"
  writeAt(1, 6, siloHdr)
  writeAt(mid + 2, 6, outHdr)

  local siloListLocal = siloList()
  local outListLocal = outpostList()
  local maxRows = h - 9
  if maxRows < 1 then maxRows = 1 end

  for i = 1, maxRows do
    local y = 6 + i
    local sAddr = siloListLocal[i]
    if sAddr then
      local e = silos[sAddr]
      local mark = (i == selectedSilo) and ">" or " "
      local sid = (e and e.nodeId) or sAddr
      local seen = e and (now() - (e.lastSeen or 0)) or 999
      local st = e and e.state
      local busy = st and st.busy and "BUSY" or "IDLE"
      local armed = st and st.armed and "ARM" or "SAFE"
      local auto = st and st.autoStandby and "AUTO" or "MAN"
      local dock = st and st.docked and "DOCK" or "----"
      local hf = st and st.homeFreq or nil
      local hfOk = st and (st.homeFreqValid == true)
      local hfStr = tostring(hf or "?") .. (hfOk and "" or "!")
      local midShort = st and st.missionId and tostring(st.missionId):sub(1, 6) or ""
      local line = string.format("%s %d) %s | %s %s %s %s | hf=%s | %s | %.1fs", mark, i, sid, armed, auto, busy, dock, hfStr, midShort, seen)
      writeAt(1, y, line:sub(1, mid - 1))
    end

    local oAddr = outListLocal[i]
    if oAddr then
      local e = outposts[oAddr]
      local mark = (i == selectedOutpost) and ">" or " "
      local oid = (e and e.nodeId) or oAddr
      local seen = e and (now() - (e.lastSeen or 0)) or 999
      local info = e and e.info or nil
      local st = e and e.state or nil
      local pf = info and info.padFreq or nil
      local planet = info and info.planetName or nil
      local pfOk = info and (info.padFreqValid == true)
      local req = requests[oid]
      local reqStr = req and (req.status or "REQ") or "--"
      local pfStr = tostring(pf or "?") .. (pfOk and "" or "!")
      local stage = st and st.stage or nil
      local susp = st and st.suspended == true
      local stageStr = stage and tostring(stage) or "--"
      if susp then stageStr = stageStr .. " SUSP" end
      local line = string.format("%s %d) %s | %s | f=%s | %s | %.1fs", mark, i, oid, tostring(planet or "?"), pfStr, stageStr, seen)
      if req then line = line .. " | " .. reqStr end
      writeAt(mid + 2, y, line:sub(1, w - (mid + 1)))
    end
  end

  -- Mission panel (last few by lastUpdateAt)
  local mlineY = h - 6
  local list = {}
  for mid2, m in pairs(missions) do
    if m and m.state and m.state ~= "COMPLETE" and m.state ~= "ABORTED" then
      table.insert(list, {mid = mid2, t = m.lastUpdateAt or m.createdAt or 0})
    end
  end
  table.sort(list, function(a, b) return a.t > b.t end)
  writeAt(1, mlineY, "MISSIONS")
  for i = 1, 3 do
    local item = list[i]
    local y = mlineY + i
    if item then
      local m = missions[item.mid]
      local midShort = tostring(item.mid):sub(1, 8)
      local line = string.format("%s | %s -> %s | %s", midShort, tostring(m.outpostId), tostring(m.siloId or "(unassigned)"), tostring(m.state))
      writeAt(1, y, line:sub(1, w))
    else
      writeAt(1, y, "")
    end
  end

  writeAt(1, h - 2, string.rep("-", w))
  writeAt(1, h - 1, "Status: " .. tostring(status or uiStatus or "Ready"))
end

local function drawSiloDetail(status)
  term.clear()
  local w, h = 80, 25
  if term.getViewport then w, h = term.getViewport() end
  local mid = math.floor(w / 2)
  local addr = selectedAddr()
  local e = addr and silos[addr] or nil
  local sid = (e and e.nodeId) or (addr or "(none)")
  local st = e and e.state or {}
  local seen = e and (now() - (e.lastSeen or 0)) or 999

  writeAt(1, 1, "SILO: " .. tostring(sid))
  writeAt(1, 2, "Keys: W/S move | Enter select | Backspace/Esc back | Q quit")
  writeAt(1, 3, string.rep("-", w))

  -- Left: state + history
  writeAt(1, 4, "STATE")
  writeAt(1, 5, string.format("Seen: %.1fs", seen))
  writeAt(1, 6, string.format("Armed: %s", st.armed and "YES" or "NO"))
  writeAt(1, 7, string.format("AUTO:  %s", st.autoStandby and "WAITING" or "OFF"))
  writeAt(1, 8, string.format("Busy:  %s", st.busy and "YES" or "NO"))
  writeAt(1, 9, string.format("Docked:%s", st.docked and "YES" or "NO"))
  local hfStr = tostring(st.homeFreq or "?") .. ((st.homeFreqValid == true) and "" or "!")
  writeAt(1, 10, "HomeFreq: " .. hfStr)
  writeAt(1, 11, "Mission: " .. tostring(st.missionId or st.lastMissionId or "--"))
  writeAt(1, 12, "Result:  " .. tostring(st.lastMissionResult or "--"))

  writeAt(1, 14, "HISTORY")
  local hist = buildHistoryLines(function(m)
    return m.siloId and tostring(m.siloId) == tostring(sid)
  end, h - 17)
  for i = 1, (h - 17) do
    local y = 14 + i
    local line = hist[i] or ""
    writeAt(1, y, line:sub(1, mid - 2))
  end

  -- Right: controls
  writeAt(mid + 2, 4, "CONTROLS")
  local menu = {
    "Arm",
    "Disarm",
    "AUTO standby",
    "Abort",
    "Ping",
    "Back",
  }
  for i = 1, #menu do
    local y = 4 + i
    local mark = (i == menuIndex) and ">" or " "
    writeAt(mid + 2, y, (mark .. " " .. menu[i]):sub(1, w - (mid + 1)))
  end

  writeAt(1, h - 2, string.rep("-", w))
  writeAt(1, h - 1, "Status: " .. tostring(status or uiStatus or "Ready"))
end

local function drawOutpostDetail(status)
  term.clear()
  local w, h = 80, 25
  if term.getViewport then w, h = term.getViewport() end
  local mid = math.floor(w / 2)
  local addr = selectedOutpostAddr()
  local e = addr and outposts[addr] or nil
  local oid = (e and e.nodeId) or (addr or "(none)")
  local seen = e and (now() - (e.lastSeen or 0)) or 999
  local info = e and e.info or {}
  local st = e and e.state or {}
  local pfStr = tostring(info.padFreq or "?") .. ((info.padFreqValid == true) and "" or "!")
  local req = requests[oid]

  writeAt(1, 1, "OUTPOST: " .. tostring(oid))
  writeAt(1, 2, "Keys: W/S move | Enter select | Backspace/Esc back | Q quit")
  writeAt(1, 3, string.rep("-", w))

  -- Left: state
  writeAt(1, 4, "STATE")
  writeAt(1, 5, "Planet: " .. tostring(info.planetName or "?"))
  writeAt(1, 6, "Seen:   " .. string.format("%.1fs", seen))
  writeAt(1, 7, "Pad f:  " .. pfStr)
  writeAt(1, 8, "Stage:  " .. tostring(st.stage or "--"))
  writeAt(1, 9, "Susp:   " .. ((st.suspended == true) and "YES" or "NO"))
  if st.blockedReason then
    writeAt(1, 10, "Block:  " .. tostring(st.blockedReason))
  end
  if st.itemCells ~= nil and st.fluidCells ~= nil then
    writeAt(1, 11, string.format("Cells:  ic=%s fc=%s", tostring(st.itemCells), tostring(st.fluidCells)))
  end
  if req then
    writeAt(1, 12, "Req:    " .. tostring(req.status or "--"))
  end

  writeAt(1, 14, "HISTORY")
  local hist = buildHistoryLines(function(m)
    return m.outpostId and tostring(m.outpostId) == tostring(oid)
  end, h - 17)
  for i = 1, (h - 17) do
    local y = 14 + i
    local line = hist[i] or ""
    writeAt(1, y, line:sub(1, mid - 2))
  end

  -- Right: actions
  writeAt(mid + 2, 4, "ACTIONS")
  local pickupEnabled = (st.suspended ~= true)
  local menu = {
    {label = "Manual pickup request", enabled = pickupEnabled},
    {label = "Back", enabled = true},
  }
  for i = 1, #menu do
    local y = 4 + i
    local mark = (i == menuIndex) and ">" or " "
    local text = menu[i].label
    if not menu[i].enabled then text = text .. " (disabled)" end
    writeAt(mid + 2, y, (mark .. " " .. text):sub(1, w - (mid + 1)))
  end

  writeAt(1, h - 2, string.rep("-", w))
  writeAt(1, h - 1, "Status: " .. tostring(status or uiStatus or "Ready"))
end

local function draw(status)
  if view == "silo_detail" then
    return drawSiloDetail(status)
  elseif view == "outpost_detail" then
    return drawOutpostDetail(status)
  end
  return drawMain(status)
end

local function missionLog(mid, msg)
  local m = missions[mid]
  if not m then return end
  m.lastUpdateAt = now()
  m.log = m.log or {}
  table.insert(m.log, {t = now(), msg = msg})
  if #m.log > 30 then
    table.remove(m.log, 1)
  end
end

local function setMissionState(mid, state, msg)
  local m = missions[mid]
  if not m then return end
  m.state = state
  missionLog(mid, msg or ("state=" .. tostring(state)))
end

local function releaseMissionLocks(mid)
  local m = missions[mid]
  if not m then return end
  if m.siloId then siloActiveMission[m.siloId] = nil end
  if m.outpostId then outpostActiveMission[m.outpostId] = nil end
end

local function queueCmd(addr, payload, meta)
  if NET_MODE == "modem" and not addr then return end
  local id = msgId()
  local pkt = {kind = "CMD", msgId = id, to = "silo", payload = payload}
  pending[id] = {addr = addr, pkt = pkt, nextSendAt = 0, retries = 0, meta = meta}
  return id
end

local function queueToNode(addr, kind, payload, meta)
  if NET_MODE == "modem" and not addr then return end
  local id = msgId()
  local pkt = {kind = kind, msgId = id, payload = payload}
  pending[id] = {addr = addr, pkt = pkt, nextSendAt = 0, retries = 0, meta = meta}
  return id
end

local function pickAvailableSilo()
  for _, addr in ipairs(siloOrder) do
    local e = silos[addr]
    local st = e and e.state
    if e and st and st.autoStandby and st.armed and (not st.busy) and (st.homeFreqValid == true) and (st.homeFreq ~= nil) then
      if not siloActiveMission[e.nodeId] then
        return addr, e
      end
    end
  end
end

local function createMissionForOutpost(outpostId, planetName)
  local existing = outpostActiveMission[outpostId]
  if existing and missions[existing] then
    local st = missions[existing].state
    local terminal = (st == "COMPLETE") or (st == "ABORTED") or (type(st) == "string" and st:match("^FAILED"))
    if not terminal then
      return existing
    end
  end

  local mid = msgId()
  missions[mid] = {
    outpostId = outpostId,
    planetName = planetName,
    outpostFreq = nil,
    returnFreq = nil,
    needEmptyItems = nil,
    needEmptyFluids = nil,
    siloId = nil,
    siloAddr = nil,
    state = "REQUESTED",
    createdAt = now(),
    lastUpdateAt = now(),
    log = {},
  }
  outpostActiveMission[outpostId] = mid
  missionLog(mid, "created")
  return mid
end

local function dispatchPickup(outpostId)
  local req = requests[outpostId]
  if not req then return false, "no request" end
  if req.status == "ASSIGNED" or req.status == "DISPATCHING" then return false, "already assigned" end

  if req.padFreqValid ~= true then
    req.status = "BAD_OUTPOST_FREQ"
    if req.missionId and missions[req.missionId] then missions[req.missionId].state = "BAD_OUTPOST_FREQ" end
    return false, "outpost source frequency invalid"
  end

  if not req.padFreq then
    req.status = "BAD_OUTPOST_FREQ"
    if req.missionId and missions[req.missionId] then missions[req.missionId].state = "BAD_OUTPOST_FREQ" end
    return false, "missing outpost frequency"
  end

  local siloAddr, siloEntry = pickAvailableSilo()
  if not siloAddr then
    req.status = "WAIT_SILO"
    if req.missionId and missions[req.missionId] then missions[req.missionId].state = "WAIT_SILO" end
    return false, "no available silo"
  end

  local missionId = req.missionId
  local m = missionId and missions[missionId] or nil
  if not m then
    missionId = createMissionForOutpost(outpostId, req.planetName)
    req.missionId = missionId
    m = missions[missionId]
  end

  local siloHomeFreq = siloEntry and siloEntry.state and siloEntry.state.homeFreq or nil
  m.outpostFreq = req.padFreq
  m.returnFreq = siloHomeFreq

  -- Snapshot replacement counts at dispatch time.
  m.needEmptyItems = tonumber(req.itemCells) or 0
  m.needEmptyFluids = tonumber(req.fluidCells) or 0
  missionLog(missionId, "replacement snapshot items=" .. tostring(m.needEmptyItems) .. " fluids=" .. tostring(m.needEmptyFluids))
  m.siloAddr = siloAddr
  m.siloId = siloEntry and siloEntry.nodeId or nil
  setMissionState(missionId, "DISPATCHING", "dispatching to " .. tostring(m.siloId))

  -- lock silo to this mission
  if m.siloId then siloActiveMission[m.siloId] = missionId end

  req.status = "DISPATCHING"

  m.startMsgId = queueCmd(siloAddr, {startMission = {
    missionId = missionId,
    outpostId = outpostId,
    dstFreq = req.padFreq,
    needEmptyItems = m.needEmptyItems,
    needEmptyFluids = m.needEmptyFluids,
  }}, {missionId = missionId, type = "startMission"})

  -- Tell outpost which mission and which return frequency to use.
  local oAddr = req.addr or findOutpostAddrById(outpostId)
  if oAddr and siloHomeFreq then
    m.assignMsgId = queueToNode(oAddr, "CMD", {missionAssigned = {missionId = missionId, outpostId = outpostId, returnFreq = siloHomeFreq, siloId = missions[missionId].siloId}}, {missionId = missionId, type = "missionAssigned"})
  end
  -- Stay in DISPATCHING until silo accepts; request is still logically assigned.
  req.status = "DISPATCHING"
  return true, "dispatching " .. tostring(missionId)
end

local function tryDispatchOldestPending()
  -- Oldest request first; keep original requestedAt.
  local oldestId = nil
  local oldestT = nil
  for outpostId, req in pairs(requests) do
    if req and (req.status == "PENDING" or req.status == "WAIT_SILO") then
      if req.padFreqValid == true and req.padFreq ~= nil then
        if (not oldestT) or (req.requestedAt < oldestT) then
          oldestT = req.requestedAt
          oldestId = outpostId
        end
      end
    end
  end
  if oldestId then
    return dispatchPickup(oldestId)
  end
end

local function schedulerTick(force)
  if not force then
    if now() - lastSchedAt < SCHED_PERIOD then return end
  end
  lastSchedAt = now()

  local ok, msg = tryDispatchOldestPending()
  if ok then
    uiStatus = "Dispatch: " .. tostring(msg)
  elseif msg then
    uiStatus = "Dispatch: " .. tostring(msg)
  end
end

local function timeoutTick()
  if now() - lastTimeoutAt < TIMEOUT_TICK then return end
  lastTimeoutAt = now()

  for mid, m in pairs(missions) do
    if m and m.state and m.state ~= "COMPLETE" and m.state ~= "ABORTED" then
      local age = now() - (m.lastUpdateAt or m.createdAt or now())
      if m.state == "DISPATCHING" and age > DISPATCH_TIMEOUT then
        missionLog(mid, "dispatch timeout; requeue")
        if m.siloId then siloActiveMission[m.siloId] = nil end
        m.siloId = nil
        m.siloAddr = nil
        m.state = "WAIT_SILO"
        if requests[m.outpostId] then requests[m.outpostId].status = "WAIT_SILO" end
      elseif (m.state == "SILO_RUNNING" or m.state == "OUTPOST_WAIT_DOCK" or m.state == "OUTPOST_LAUNCHING_HOME" or m.state == "HOME_INBOUND") and age > LONG_TIMEOUT then
        -- Don't unlock (rocket may be away); just mark as stale so UI shows it.
        missionLog(mid, "stale timeout")
        m.state = "STALE_" .. tostring(m.state)
      end
    end
  end
end

local function processPending()
  for id, p in pairs(pending) do
    if now() >= (p.nextSendAt or 0) then
      if p.retries >= CMD_MAX_RETRIES then
        -- Mark mission as needing re-dispatch if this was critical.
        local meta = p.meta
        if meta and meta.missionId and missions[meta.missionId] then
          local m = missions[meta.missionId]
          if meta.type == "startMission" then
            missionLog(meta.missionId, "startMission send failed")
            if m.siloId then siloActiveMission[m.siloId] = nil end
            m.siloId = nil
            m.siloAddr = nil
            m.state = "WAIT_SILO"
            if requests[m.outpostId] then requests[m.outpostId].status = "WAIT_SILO" end
          elseif meta.type == "homeInbound" then
            missionLog(meta.missionId, "homeInbound send failed")
          elseif meta.type == "missionAssigned" then
            missionLog(meta.missionId, "missionAssigned send failed")
            -- Outpost will retry pickup; we'll resend missionAssigned then.
          end
        end
        pending[id] = nil
      else
        sendPkt(p.addr, p.pkt)
        p.retries = p.retries + 1
        p.nextSendAt = now() + CMD_RETRY_PERIOD
      end
    end
  end
end

local function handlePacket(remote, pkt)
  if type(pkt) ~= "table" or pkt.v ~= 1 or type(pkt.msgId) ~= "string" then return end
  cleanupSeen()
  if seenMsg[pkt.msgId] then
    if pkt.kind ~= "ACK" then ack(remote, pkt.msgId) end
    return
  end
  seenMsg[pkt.msgId] = now()

  if pkt.kind == "ACK" then
    local ackId = pkt.payload and pkt.payload.ack
    if ackId and pending[ackId] then
      local meta = pending[ackId].meta
      if meta and meta.missionId and missions[meta.missionId] then
        missionLog(meta.missionId, "acked " .. tostring(meta.type))
      end
      pending[ackId] = nil
    end
    return
  end

  -- Ack all non-ACK packets
  ack(remote, pkt.msgId)

  if pkt.kind == "HELLO" then
    local role = pkt.payload and pkt.payload.role
    if role == "outpost" then
      addOrUpdateOutpost(remote, pkt.payload)
    else
      addOrUpdateSilo(remote, pkt.payload)
    end
  elseif pkt.kind == "STATUS" then
    -- payload in STATUS is {reason=..., state=...}
    if silos[remote] and pkt.payload and pkt.payload.state then
      silos[remote].state = pkt.payload.state
      silos[remote].lastSeen = now()

      -- Mission tracking from silo
      local st = pkt.payload.state
      local mid = st.missionId or st.lastMissionId
      if mid and missions[mid] then
        local m = missions[mid]
        if pkt.payload.reason == "cmd:startMission" then
          setMissionState(mid, "SILO_ACCEPTED", "silo accepted")
          if requests[m.outpostId] then requests[m.outpostId].status = "ASSIGNED" end
        elseif pkt.payload.reason == "preflight:craft_requested" then
          setMissionState(mid, "SILO_PREFLIGHT_CRAFTING", "silo crafting empties")
        elseif pkt.payload.reason == "preflight:staging_ready" then
          setMissionState(mid, "SILO_PREFLIGHT_STAGING_READY", "empties staged")
        elseif pkt.payload.reason == "preflight:loaded_empties" then
          setMissionState(mid, "SILO_PREFLIGHT_LOADED_EMPTIES", "empties loaded")
        elseif pkt.payload.reason == "auto:start" then
          setMissionState(mid, "SILO_RUNNING", "silo running")
        elseif pkt.payload.reason == "auto:complete" or pkt.payload.reason == "mission:done" then
          setMissionState(mid, "COMPLETE", "complete")
          releaseMissionLocks(mid)
          if requests[m.outpostId] then requests[m.outpostId].status = "DONE" end
        elseif pkt.payload.reason == "auto:aborted" then
          setMissionState(mid, "ABORTED", "aborted")
          releaseMissionLocks(mid)
          if requests[m.outpostId] then requests[m.outpostId].status = "ABORTED" end
        elseif pkt.payload.reason == "reject:not_standby" then
          setMissionState(mid, "WAIT_SILO", "rejected (not standby)")
          if m.siloId then siloActiveMission[m.siloId] = nil end
          m.siloId = nil
          m.siloAddr = nil
          if requests[m.outpostId] then requests[m.outpostId].status = "WAIT_SILO" end
        elseif pkt.payload.reason == "reject:bad_dst_freq" then
          setMissionState(mid, "FAILED_BAD_DST_FREQ", "silo rejected invalid dst")
          releaseMissionLocks(mid)
          if requests[m.outpostId] then requests[m.outpostId].status = "FAILED_BAD_DST_FREQ" end
        elseif pkt.payload.reason == "net:homeInbound_received" then
          setMissionState(mid, "SILO_HOME_ACK", "silo received home inbound")
        elseif type(pkt.payload.reason) == "string" and pkt.payload.reason:match("^reject:") then
          setMissionState(mid, "FAILED_" .. pkt.payload.reason:gsub("^reject:", ""), "silo rejected: " .. pkt.payload.reason)
          releaseMissionLocks(mid)
          if requests[m.outpostId] then requests[m.outpostId].status = "FAILED" end
        end
      end

      -- Silo became eligible? try dispatch immediately.
      local sid = st.siloId or (silos[remote] and silos[remote].nodeId)
      if sid then
        local eligible = (st.autoStandby == true) and (st.armed == true) and (st.busy ~= true) and (st.homeFreqValid == true) and (st.homeFreq ~= nil) and (not siloActiveMission[sid])
        local prev = siloEligible[sid]
        siloEligible[sid] = eligible
        if eligible and not prev then
          schedulerTick(true)
        end
      end
    elseif outposts[remote] and pkt.payload and pkt.payload.state then
      outposts[remote].state = pkt.payload.state
      outposts[remote].lastSeen = now()

      -- Mission tracking from outpost stage
      local st = pkt.payload.state
      local mid = st.missionId
      if mid and missions[mid] then
        local m = missions[mid]
        if st.stage == "WAIT_DOCK" then
          setMissionState(mid, "OUTPOST_WAIT_DOCK", "outpost waiting dock")
        elseif st.stage == "UNLOADING" then
          setMissionState(mid, "OUTPOST_UNLOADING", "outpost unloading")
        elseif st.stage == "LOADING" then
          setMissionState(mid, "OUTPOST_LOADING", "outpost loading")
        elseif st.stage == "BLOCKED_UNLOAD" then
          setMissionState(mid, "OUTPOST_BLOCKED_UNLOAD", "outpost blocked unload")
        elseif st.stage == "RECALLING_HOME" then
          setMissionState(mid, "OUTPOST_RECALLING", "outpost recalling")
        elseif st.stage == "LAUNCHING_HOME" then
          setMissionState(mid, "OUTPOST_LAUNCHING_HOME", "outpost launching home")
        end
      end
    end
  elseif pkt.kind == "PONG" then
    if silos[remote] and pkt.payload and pkt.payload.state then
      silos[remote].state = pkt.payload.state
      silos[remote].lastSeen = now()
    elseif outposts[remote] and pkt.payload and pkt.payload.state then
      outposts[remote].state = pkt.payload.state
      outposts[remote].lastSeen = now()
    end
  elseif pkt.kind == "PICKUP_REQUEST" then
    -- from an outpost
    local outpostId = pkt.payload and (pkt.payload.outpostId or pkt.payload.nodeId)
    local padFreq = pkt.payload and tonumber(pkt.payload.padFreq)
    local padFreqValid = pkt.payload and (pkt.payload.padFreqValid == true)
    local planetName = pkt.payload and pkt.payload.planetName
    local itemCells = pkt.payload and tonumber(pkt.payload.itemCells)
    local fluidCells = pkt.payload and tonumber(pkt.payload.fluidCells)
    if outpostId then
      local req = requests[outpostId]
      if not req or req.status == "DONE" or req.status == "ABORTED" then
        req = {
          requestedAt = now(),
          status = "PENDING",
        }
        requests[outpostId] = req
      end

      -- Preserve original requestedAt; update live data.
      req.padFreq = padFreq
      req.padFreqValid = padFreqValid
      req.planetName = planetName
      req.addr = remote
      req.itemCells = itemCells
      req.fluidCells = fluidCells

      local function missionTerminal(mid)
        local m = mid and missions[mid] or nil
        if not m then return true end
        local st = m.state
        return (st == "COMPLETE") or (st == "ABORTED") or (type(st) == "string" and st:match("^FAILED"))
      end

      if not req.missionId or missionTerminal(req.missionId) then
        req.missionId = createMissionForOutpost(outpostId, planetName)
      end
      local mid = req.missionId
      missions[mid].outpostFreq = padFreq
      if padFreqValid ~= true then
        missions[mid].state = "BAD_OUTPOST_FREQ"
        missionLog(mid, "bad outpost frequency")
        req.status = "BAD_OUTPOST_FREQ"
        uiStatus = "Pickup blocked: outpost freq invalid"
      else
        missions[mid].state = missions[mid].state == "REQUESTED" and "REQUESTED" or missions[mid].state
        missionLog(mid, "pickup request received")
        -- If already assigned, re-send missionAssigned (outpost retries until it gets it).
        if req.status == "ASSIGNED" and req.missionId and missions[req.missionId] and missions[req.missionId].returnFreq then
          local m = missions[req.missionId]
          local oAddr = req.addr or findOutpostAddrById(outpostId)
          if oAddr and m.returnFreq then
            queueToNode(oAddr, "CMD", {missionAssigned = {missionId = req.missionId, outpostId = outpostId, returnFreq = m.returnFreq, siloId = m.siloId}}, {missionId = req.missionId, type = "missionAssigned"})
            missionLog(req.missionId, "resent missionAssigned")
          end
          uiStatus = "Pickup retry: resent assignment"
        elseif req.status == "DISPATCHING" then
          uiStatus = "Pickup request: dispatching"
        elseif req.status == "WAIT_SILO" then
          uiStatus = "Pickup request: waiting for silo"
        else
          -- Don't force immediate dispatch; scheduler does oldest-first.
          if not req.status or req.status == "BAD_OUTPOST_FREQ" then
            req.status = "PENDING"
          end
          uiStatus = "Pickup requested: " .. tostring(outpostId) .. " | mid=" .. tostring(mid):sub(1, 8)
        end
      end
    end
  elseif pkt.kind == "HOME_INBOUND" then
    local outpostId = pkt.payload and (pkt.payload.outpostId or pkt.payload.nodeId)
    local mid = pkt.payload and pkt.payload.missionId
    if mid and missions[mid] and missions[mid].siloAddr then
      local m = missions[mid]
      m.state = "HOME_INBOUND"
      missionLog(mid, "home inbound received")
      -- Rate limit forwarding to avoid spam (outpost may retry broadcast).
      m.lastHomeFwdAt = m.lastHomeFwdAt or 0
      if now() - m.lastHomeFwdAt >= 2.0 then
        m.lastHomeFwdAt = now()
        queueCmd(m.siloAddr, {homeInbound = {missionId = mid, outpostId = outpostId}}, {missionId = mid, type = "homeInbound"})
        missionLog(mid, "home inbound forwarded")
      end
      uiStatus = "HOME_INBOUND forwarded to " .. tostring(m.siloId or "silo")
    elseif outpostId and requests[outpostId] and requests[outpostId].missionId then
      -- fallback for older outpost scripts
      local mid2 = requests[outpostId].missionId
      local m2 = missions[mid2]
      if m2 and m2.siloAddr then
        m2.state = "HOME_INBOUND"
        missionLog(mid2, "home inbound received (fallback)")
        queueCmd(m2.siloAddr, {homeInbound = {missionId = mid2, outpostId = outpostId}}, {missionId = mid2, type = "homeInbound"})
        uiStatus = "HOME_INBOUND forwarded to " .. tostring(m2.siloId or "silo")
      end
    end
  end
end

local function handleNetEvent(_localAddr, remoteAddr, port, _distance, data)
  if NET_MODE == "modem" then
    if not modem or _localAddr ~= modem.address then return end
    if port ~= NET_PORT then return end
  elseif NET_MODE == "tunnel" then
    if not tunnel or _localAddr ~= tunnel.address then return end
    -- ignore port
  else
    return
  end
  if type(data) ~= "string" then return end
  local ok, pkt = pcall(serialization.unserialize, data)
  if not ok then return end
  handlePacket(remoteAddr, pkt)
end

-- init
pcall(function()
  local up = dofile("/home/updater.lua")
  if up and up.run then up.run({manifestUrl = UPDATE_MANIFEST_URL, currentVersion = SCRIPT_VERSION, target = "hq"}) end
end)

if NET_MODE == "modem" and modem then
  modem.open(NET_PORT)
elseif NET_FORCE_MODE == "modem" then
  error("Forced modem mode but no modem found")
end
math.randomseed(math.floor(computer.uptime() * 1000000) % 2147483647)

draw(uiStatus)

while true do
  processPending()
  schedulerTick()
  timeoutTick()

  local ev, a1, a2, a3, a4, a5 = event.pull(0.2)
  if ev == "modem_message" then
    handleNetEvent(a1, a2, a3, a4, a5)
    draw()
  elseif ev == "key_down" then
    local ch = a2
    local code = a3

    if isCharKey(ch, "q") then
      break
    end

    local up = isCharKey(ch, "w") or isKeyCode(code, "up")
    local down = isCharKey(ch, "s") or isKeyCode(code, "down")
    local left = isCharKey(ch, "a") or isKeyCode(code, "left")
    local right = isCharKey(ch, "d") or isKeyCode(code, "right")
    local enter = (type(ch) == "number" and ch == 13) or isKeyCode(code, "enter") or isKeyCode(code, "numpadenter")
    local back = (type(ch) == "number" and ch == 8) or isKeyCode(code, "back") or isKeyCode(code, "backspace") or isKeyCode(code, "escape")

    if view == "main" then
      if left then
        focus = "silo"
      elseif right then
        focus = "outpost"
      elseif up then
        if focus == "silo" then
          selectedSilo = selectedSilo - 1
        else
          selectedOutpost = selectedOutpost - 1
        end
      elseif down then
        if focus == "silo" then
          selectedSilo = selectedSilo + 1
        else
          selectedOutpost = selectedOutpost + 1
        end
      elseif enter then
        if focus == "silo" then
          local addr = selectedAddr()
          if addr then
            view = "silo_detail"
            menuIndex = 1
          else
            uiStatus = "No silo selected"
          end
        else
          local addr = selectedOutpostAddr()
          if addr then
            view = "outpost_detail"
            menuIndex = 1
          else
            uiStatus = "No outpost selected"
          end
        end
      end
    elseif view == "silo_detail" then
      local menuLen = 6
      if back then
        view = "main"
        menuIndex = 1
      elseif up then
        menuIndex = menuIndex - 1
      elseif down then
        menuIndex = menuIndex + 1
      elseif enter then
        local addr = selectedAddr()
        if not addr then
          uiStatus = "No silo selected"
          view = "main"
        else
          if menuIndex == 1 then
            queueCmd(addr, {arm = true})
            uiStatus = "Sent arm"
          elseif menuIndex == 2 then
            queueCmd(addr, {arm = false})
            uiStatus = "Sent disarm"
          elseif menuIndex == 3 then
            queueCmd(addr, {autoStart = true})
            uiStatus = "Sent AUTO standby"
          elseif menuIndex == 4 then
            queueCmd(addr, {abort = true})
            uiStatus = "Sent abort"
          elseif menuIndex == 5 then
            sendPkt(addr, {kind = "PING", msgId = msgId(), payload = {}})
            uiStatus = "Ping sent"
          elseif menuIndex == 6 then
            view = "main"
            menuIndex = 1
          end
        end
      end
      if menuIndex < 1 then menuIndex = 1 end
      if menuIndex > menuLen then menuIndex = menuLen end
    elseif view == "outpost_detail" then
      local menuLen = 2
      if back then
        view = "main"
        menuIndex = 1
      elseif up then
        menuIndex = menuIndex - 1
      elseif down then
        menuIndex = menuIndex + 1
      elseif enter then
        local addr = selectedOutpostAddr()
        local e = addr and outposts[addr] or nil
        local oid = (e and e.nodeId) or nil
        local st = e and e.state or nil
        if menuIndex == 1 then
          if not addr or not oid then
            uiStatus = "No outpost selected"
          elseif st and st.suspended == true then
            uiStatus = "Outpost suspended; fix locally"
          else
            queueToNode(addr, "CMD", {forcePickup = {manual = true}}, {type = "forcePickup", outpostId = oid})
            uiStatus = "Force pickup sent to " .. tostring(oid)
          end
        elseif menuIndex == 2 then
          view = "main"
          menuIndex = 1
        end
      end
      if menuIndex < 1 then menuIndex = 1 end
      if menuIndex > menuLen then menuIndex = menuLen end
    end

    -- clamp selections
    local sN = #siloList()
    if selectedSilo < 1 then selectedSilo = 1 end
    if selectedSilo > sN then selectedSilo = sN end
    if selectedSilo < 1 then selectedSilo = 1 end
    local oN = #outpostList()
    if selectedOutpost < 1 then selectedOutpost = 1 end
    if selectedOutpost > oN then selectedOutpost = oN end
    if selectedOutpost < 1 then selectedOutpost = 1 end

    draw()
  end
end

term.clear()
print("HQ closed.")
