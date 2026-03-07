-- Simple self-updater for OpenComputers scripts (GitHub raw)
--
-- Usage from a script:
--   local ok, up = pcall(dofile, "/home/updater.lua")
--   if ok and up then up.run{manifestUrl=..., currentVersion=..., target="hq"} end

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local term = require("term")

local M = {}

local function now() return computer.uptime() end

local function readAll(handle)
  local chunks = {}
  while true do
    local data = handle.read(math.huge)
    if not data then break end
    chunks[#chunks + 1] = data
  end
  return table.concat(chunks)
end

local function httpGet(url)
  if not component.isAvailable("internet") then
    return nil, "no internet card"
  end
  local internet = component.internet
  local handle, err = internet.request(url)
  if not handle then
    return nil, tostring(err)
  end
  local ok, body = pcall(readAll, handle)
  handle.close()
  if not ok then
    return nil, tostring(body)
  end
  return body
end

local function parseSemver(v)
  if type(v) ~= "string" then return nil end
  local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c)
end

local function isNewer(remote, localV)
  if remote == localV then return false end
  local ra, rb, rc = parseSemver(remote)
  local la, lb, lc = parseSemver(localV)
  if ra and la then
    if ra ~= la then return ra > la end
    if rb ~= lb then return rb > lb end
    return rc > lc
  end
  -- fallback: treat change as "newer"
  return true
end

local function parseManifest(text)
  if type(text) ~= "string" then return nil, "bad manifest" end
  local env = {}
  local fn, err = load(text, "=manifest", "t", env)
  if not fn then return nil, tostring(err) end
  local ok, res = pcall(fn)
  if not ok then return nil, tostring(res) end
  if type(res) ~= "table" then return nil, "manifest must return table" end
  return res
end

local function baseUrlFromManifestUrl(url)
  return (url:gsub("[^/]+$", ""))
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

local function safeReplace(path, newContent)
  local tmp = path .. ".new"
  local bak = path .. ".bak"

  local ok, err = writeFile(tmp, newContent)
  if not ok then return false, "write tmp failed: " .. tostring(err) end

  if filesystem.exists(bak) then
    pcall(filesystem.remove, bak)
  end
  if filesystem.exists(path) then
    filesystem.rename(path, bak)
  end
  filesystem.rename(tmp, path)
  return true
end

local function promptToUpdate(title, timeout)
  term.clear()
  print(title)
  print("")
  print("Press U to update now, any other key to skip.")
  if timeout and timeout > 0 then
    print("(auto-continue in " .. tostring(timeout) .. "s)")
  end

  local deadline = timeout and (now() + timeout) or nil
  while true do
    local remaining = deadline and (deadline - now()) or math.huge
    if deadline and remaining <= 0 then return false end
    local ev, _addr, ch = event.pull(remaining, "key_down")
    if ev == nil then return false end
    if type(ch) == "number" then
      local c = string.char(ch)
      return c == "u" or c == "U"
    end
    return false
  end
end

function M.run(opts)
  opts = opts or {}
  local manifestUrl = opts.manifestUrl
  local currentVersion = opts.currentVersion or "0.0.0"
  local target = opts.target or "all"
  local promptTimeout = opts.promptTimeout
  if promptTimeout == nil then promptTimeout = 8 end

  if type(manifestUrl) ~= "string" or manifestUrl == "" or manifestUrl:find("<", 1, true) then
    return false, "no manifestUrl configured"
  end

  local body, err = httpGet(manifestUrl)
  if not body then
    return false, "manifest fetch failed: " .. tostring(err)
  end
  local manifest, perr = parseManifest(body)
  if not manifest then
    return false, "manifest parse failed: " .. tostring(perr)
  end
  local remoteVersion = manifest.version or ""
  if type(remoteVersion) ~= "string" then remoteVersion = tostring(remoteVersion) end

  if not isNewer(remoteVersion, currentVersion) then
    return true, "up to date"
  end

  local okPrompt = promptToUpdate("Update available: " .. tostring(currentVersion) .. " -> " .. tostring(remoteVersion), promptTimeout)
  if not okPrompt then
    return true, "skipped"
  end

  local base = baseUrlFromManifestUrl(manifestUrl)
  local targets = manifest.targets or {}
  local list = targets[target] or targets.all
  if type(list) ~= "table" then
    return false, "manifest missing targets for " .. tostring(target)
  end

  for _, relPath in ipairs(list) do
    if type(relPath) == "string" and relPath ~= "" then
      local url = base .. relPath
      local content, ferr = httpGet(url)
      if not content then
        return false, "fetch failed: " .. tostring(relPath) .. ": " .. tostring(ferr)
      end
      local okR, rerr = safeReplace("/home/" .. relPath, content)
      if not okR then
        return false, "replace failed: " .. tostring(relPath) .. ": " .. tostring(rerr)
      end
    end
  end

  term.clear()
  print("Updated to " .. tostring(remoteVersion) .. ". Rebooting...")
  os.sleep(1)
  computer.shutdown(true)
  return true, "rebooting"
end

return M
