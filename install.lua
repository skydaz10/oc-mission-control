-- Interactive installer for oc-mission-control (GitHub raw)
--
-- Usage:
--   wget -f https://raw.githubusercontent.com/skydaz10/oc-mission-control/installer/install.lua install.lua
--   lua /home/install.lua

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local os = require("os")
local serialization = require("serialization")
local term = require("term")

local INSTALLER_VERSION = "0.2.8"

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

local DEFAULT_CHANNEL = "main"

local function branchBase(branch)
  return "https://raw.githubusercontent.com/skydaz10/oc-mission-control/" .. tostring(branch) .. "/"
end

local function parseArgs(...)
  local res = {channel = nil, noSelfUpdate = false}
  local args = {...}
  for i = 1, #args do
    local a = args[i]
    if a == "--no-self-update" then
      res.noSelfUpdate = true
    elseif a == "--channel" then
      local v = args[i + 1]
      if type(v) == "string" and v ~= "" then
        res.channel = v
      end
    elseif type(a) == "string" and a:match("^%-%-channel=") then
      res.channel = a:match("^%-%-channel=(.+)$")
    end
  end
  return res
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local REPO_RAW_BASE = nil

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

local function selfUpdateInstaller(branch)
  local url = branchBase(branch) .. "install.lua"
  local body, err = httpGet(url)
  if not body then
    return false, "self-update fetch failed: " .. tostring(err)
  end
  local localPath = "/home/install.lua"
  local cur = readFile(localPath)
  if cur == body then
    return true, "already current"
  end
  local okW, werr = writeFile(localPath, body)
  if not okW then
    return false, "self-update write failed: " .. tostring(werr)
  end
  return true, "updated"
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

local function chooseChannel()
  local idx = promptChoice("Select update channel", {"Stable (main)", "Dev (dev)"})
  return (idx == 2) and "dev" or "main"
end

local function setAutorun(startPath)
  filesystem.setAutorunEnabled(true)
  local autorun = "-- oc-mission-control autorun\n" ..
                 "pcall(dofile, '" .. startPath .. "')\n"
  return writeFile("/autorun.lua", autorun)
end

local function showChecklist(role, channel)
  term.clear()
  print("oc-mission-control installer " .. tostring(INSTALLER_VERSION))
  print("Channel: " .. tostring(channel))
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

local function install(channel)
  if not component.isAvailable("internet") then
    error("No internet card found.")
  end

  if type(channel) ~= "string" or channel == "" then
    channel = DEFAULT_CHANNEL
  end
  REPO_RAW_BASE = branchBase(channel)

  local roleIdx = promptChoice("Install oc-mission-control", {"HQ", "Silo", "Outpost"})
  local role = ({"hq", "silo", "outpost"})[roleIdx]

  local cfg = {
    role = role,
    UPDATE_MANIFEST_URL = branchBase(channel) .. "manifest.lua",
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

  showChecklist(role, channel)

  term.clear()
  print("Downloading scripts...")

  local files = {"updater.lua", "manifest.lua", "start.lua"}
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

  ok, err = setAutorun("/home/start.lua")
  if not ok then error("failed autorun.lua: " .. tostring(err)) end

  term.clear()
  print("Installed role: " .. role)
  print("Autostart configured via /autorun.lua")
  print("Rebooting...")
  os.sleep(1)
  computer.shutdown(true)
end

local opts = parseArgs(...)
local channel = opts.channel
if not channel then
  channel = chooseChannel()
end

if not opts.noSelfUpdate then
  if not component.isAvailable("internet") then
    error("No internet card found.")
  end
  local okUp, msg = selfUpdateInstaller(channel)
  if okUp and msg == "updated" then
    term.clear()
    print("Installer updated. Restarting...")
    os.sleep(0.5)
    local cmd = "lua /home/install.lua --channel " .. tostring(channel) .. " --no-self-update"
    local okShell, shell = pcall(require, "shell")
    if okShell and shell and shell.execute then
      shell.execute(cmd)
    elseif os.execute then
      os.execute(cmd)
    else
      error("cannot restart installer; run: " .. cmd)
    end
    return
  end
end

install(channel)
