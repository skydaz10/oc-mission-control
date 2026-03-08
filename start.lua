-- oc-mission-control role dispatcher
--
-- This file is intended to be called by /autorun.lua.

local function eprintln(msg)
  io.stderr:write(tostring(msg) .. "\n")
end

local ok, cfg = pcall(dofile, "/home/node_config.lua")
if not ok or type(cfg) ~= "table" then
  eprintln("oc-mission-control: missing/invalid /home/node_config.lua")
  return
end

local role = cfg.role

if role == "hq" then
  dofile("/home/hq.lua")
elseif role == "silo" then
  dofile("/home/launchcontrol.lua")
elseif role == "outpost" then
  dofile("/home/outpost.lua")
else
  eprintln("oc-mission-control: unknown role: " .. tostring(role))
end
