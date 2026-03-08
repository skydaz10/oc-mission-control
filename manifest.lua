-- GitHub raw updater manifest
-- Host this file alongside the scripts.
-- Version must be semver: major.minor.patch

return {
  version = "0.2.8",
  targets = {
    all = {"updater.lua", "start.lua", "hq.lua", "launchcontrol.lua", "outpost.lua", "install.lua", "manifest.lua"},
    hq = {"updater.lua", "start.lua", "hq.lua", "manifest.lua"},
    silo = {"updater.lua", "start.lua", "launchcontrol.lua", "manifest.lua"},
    outpost = {"updater.lua", "start.lua", "outpost.lua", "manifest.lua"},
  },
}
