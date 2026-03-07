-- Interactive installer for oc-mission-control (GitHub raw)
--
-- Usage:
--   wget -f https://raw.githubusercontent.com/skydaz10/oc-mission-control/installer/install.lua install.lua
--   lua /home/install.lua

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")
local term = require("term")

local REPO_RAW_BASE = "https://raw.githubusercontent.com/skydaz10/oc-mission-control/installer/"

local function httpGet(url)
  if not component.isAvailable("internet") then
    return nil, "no internet card"
  end
  local internet = component.internet
  local handle, err = internet.request(url)
  if not handle then
    return nil, tostring(err)
  end
  local chunks = {}
  while true do
    local data = handle.read(math.huge)
    if not data then break end
    chunks[#chunks + 1] = data
  end
  handle.close()
  return table.concat(chunks)
end

local function writeFile(path, content)
  local dir = filesystem.path(path)
  if dir and dir ~= "" and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end
  local f, err = io.open(path, "wb")
  if not f then return false, tostring(err) end
  f:write(content)
  f:close()
  return true
end

local function fetchTo(url, path)
  local body, err = httpGet(url)
  if not body then return false, err end
  local ok, werr = writeFile(path, body)
  if not ok then return false, werr end
  return true
end

local function promptLine(label, default)
  term.write(label)
  if default and default ~= "" then
    term.write(" [" .. tostring(default) .. "]")
  end
  term.write(": ")
  local s = term.read()
  s = (s or ""):gsub("\n", ""):gsub("\r", "")
  if s == "" then return default end
  return s
end

local function promptChoice(title, choices)
  while true do
    term.clear()
    print(title)
    print("")
    for i, c in ipairs(choices) do
      print(string.format("%d) %s", i, c))
    end
    print("")
    term.write("Select 1-" .. tostring(#choices) .. ": ")
    local s = term.read()
    s = (s or ""):match("%d+")
    local n = s and tonumber(s)
    if n and n >= 1 and n <= #choices then
      return n
    end
  end
end

local function setAutorun(startPath)
  filesystem.setAutorunEnabled(true)
  local autorun = "-- oc-mission-control autorun\n" ..
                 "pcall(dofile, '" .. startPath .. "')\n"
  return writeFile("/autorun.lua", autorun)
end

local function install()
  if not component.isAvailable("internet") then
    error("No internet card found.")
  end

  local roleIdx = promptChoice("Install oc-mission-control", {"HQ", "Silo", "Outpost"})
  local role = ({"hq", "silo", "outpost"})[roleIdx]

  local cfg = {
    role = role,
    UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/skydaz10/oc-mission-control/installer/manifest.lua",
  }

  local labelDefault = computer.getLabel() or ""
  if role == "hq" then
    local lbl = promptLine("Computer label", labelDefault)
    if lbl and lbl ~= "" then pcall(computer.setLabel, lbl) end
  elseif role == "silo" then
    local siloId = promptLine("Silo ID (label)", (labelDefault ~= "" and labelDefault or "SILO_01"))
    cfg.SILO_ID = siloId
    if siloId and siloId ~= "" then pcall(computer.setLabel, siloId) end
  elseif role == "outpost" then
    local outpostId = promptLine("Outpost ID (label)", (labelDefault ~= "" and labelDefault or "MOON_01"))
    local planet = promptLine("Planet name", "Moon")
    cfg.OUTPOST_ID = outpostId
    cfg.PLANET_NAME = planet
    if outpostId and outpostId ~= "" then pcall(computer.setLabel, outpostId) end
  end

  term.clear()
  print("Downloading scripts...")

  local ok, err
  ok, err = fetchTo(REPO_RAW_BASE .. "updater.lua", "/home/updater.lua")
  if not ok then error("failed updater.lua: " .. tostring(err)) end
  ok, err = fetchTo(REPO_RAW_BASE .. "manifest.lua", "/home/manifest.lua")
  if not ok then error("failed manifest.lua: " .. tostring(err)) end
  ok, err = fetchTo(REPO_RAW_BASE .. "hq.lua", "/home/hq.lua")
  if not ok then error("failed hq.lua: " .. tostring(err)) end
  ok, err = fetchTo(REPO_RAW_BASE .. "launchcontrol.lua", "/home/launchcontrol.lua")
  if not ok then error("failed launchcontrol.lua: " .. tostring(err)) end
  ok, err = fetchTo(REPO_RAW_BASE .. "outpost.lua", "/home/outpost.lua")
  if not ok then error("failed outpost.lua: " .. tostring(err)) end
  ok, err = fetchTo(REPO_RAW_BASE .. "outpost_moon.lua", "/home/outpost_moon.lua")
  if not ok then error("failed outpost_moon.lua: " .. tostring(err)) end

  local cfgText = "return " .. serialization.serialize(cfg) .. "\n"
  ok, err = writeFile("/home/node_config.lua", cfgText)
  if not ok then error("failed node_config.lua: " .. tostring(err)) end

  local start = "local cfg = dofile('/home/node_config.lua')\n" ..
                "if cfg.role == 'hq' then dofile('/home/hq.lua')\n" ..
                "elseif cfg.role == 'silo' then dofile('/home/launchcontrol.lua')\n" ..
                "elseif cfg.role == 'outpost' then dofile('/home/outpost.lua')\n" ..
                "else io.stderr:write('unknown role\n') end\n"
  ok, err = writeFile("/home/start.lua", start)
  if not ok then error("failed start.lua: " .. tostring(err)) end

  ok, err = setAutorun("/home/start.lua")
  if not ok then error("failed autorun.lua: " .. tostring(err)) end

  term.clear()
  print("Installed role: " .. role)
  print("Autostart configured via /autorun.lua")
  print("Rebooting...")
  os.sleep(1)
  computer.shutdown(true)
end

install()
