-- GitHub raw updater manifest
-- Host this file alongside the scripts.
-- Version must be semver: major.minor.patch

return {
  version = "0.1.0",
  targets = {
    all = {"updater.lua", "hq.lua", "launchcontrol.lua", "outpost_moon.lua", "manifest.lua"},
    hq = {"updater.lua", "hq.lua", "manifest.lua"},
    silo = {"updater.lua", "launchcontrol.lua", "manifest.lua"},
    outpost = {"updater.lua", "outpost_moon.lua", "manifest.lua"},
  },
}
