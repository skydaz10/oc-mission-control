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

local INSTALLER_VERSION = "0.2.4"

local function safeGetLabel()
  if type(computer.getLabel) ~= "function" then return "" end
  local ok, v = pcall(computer.getLabel)
  if ok and type(v) == "string" then return v end
  return ""
end

local function safeSetLabel(lbl)
  if type(computer.setLabel) ~= "function" then return false end
  return pcall(computer.setLabel, lbl)
end

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

local function showChecklist(role)
  term.clear()
  print("oc-mission-control installer " .. tostring(INSTALLER_VERSION))
  print("")
  print("Preflight checklist (" .. tostring(role) .. ")")
  print("-")
  print("Required: Internet Card (for install/update)")
  print("Required: Network Card (modem) on port 4242")
  if role == "outpost" then
    print("Required: cargo_launch_controller + cargo_loader + cargo_unloader + transposer")
    print("Required: transposer adjacent to cargo loader inventory (inventoryName=tile.cargo)")
    print("Important: only ONE cargo_loader/unloader in computer range")
    print("Important: pad source frequency must be valid (set in-world)")
    print("Behavior: unload timeout ~90s -> BLOCKED; auto recall after 10 min; R resets timer")
    print("Config: /home/node_config.lua supports UNLOAD_TIMEOUT, BLOCKED_RECALL_SECONDS")
  elseif role == "silo" then
    print("Required: redstone I/O + cargo_launch_controller + cargo_loader + cargo_unloader")
    print("Recommended: me_controller for mission preflight replacement empties")
    print("Important: home pad source frequency must be valid (set in-world)")
    print("Important: BLUE bundled wire is manual fallback HOME signal")
  elseif role == "hq" then
    print("Required: Network Card (modem) + screen/keyboard")
    print("Important: keep HQ on same relay network as silos/outposts")
  end
  print("")
  local s = promptLine("Type INSTALL to continue", "")
  if (s or ""):upper() ~= "INSTALL" then
    error("install cancelled")
  end
end

local function downloadFiles(list)
  for _, rel in ipairs(list) do
    local ok, err = fetchTo(REPO_RAW_BASE .. rel, "/home/" .. rel)
    if not ok then error("failed " .. tostring(rel) .. ": " .. tostring(err)) end
  end
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

  local labelDefault = safeGetLabel()
  if role == "hq" then
    local lbl = promptLine("Computer label", labelDefault)
    if lbl and lbl ~= "" then safeSetLabel(lbl) end
  elseif role == "silo" then
    local siloId = promptLine("Silo ID (label)", (labelDefault ~= "" and labelDefault or "SILO_01"))
    cfg.SILO_ID = siloId
    if siloId and siloId ~= "" then safeSetLabel(siloId) end
  elseif role == "outpost" then
    local outpostId = promptLine("Outpost ID (label)", (labelDefault ~= "" and labelDefault or "MOON_01"))
    local planet = promptLine("Planet name", "Moon")
    cfg.OUTPOST_ID = outpostId
    cfg.PLANET_NAME = planet
    if outpostId and outpostId ~= "" then safeSetLabel(outpostId) end
  end

  showChecklist(role)

  term.clear()
  print("Downloading scripts...")

  local files = {"updater.lua", "manifest.lua"}
  if role == "hq" then
    table.insert(files, "hq.lua")
  elseif role == "silo" then
    table.insert(files, "launchcontrol.lua")
  elseif role == "outpost" then
    table.insert(files, "outpost.lua")
  end
  downloadFiles(files)

  local cfgText = "return " .. serialization.serialize(cfg) .. "\n"
  local ok, err = writeFile("/home/node_config.lua", cfgText)
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
