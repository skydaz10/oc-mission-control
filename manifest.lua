-- GitHub raw updater manifest
-- Host this file alongside the scripts.
-- Version must be semver: major.minor.patch

return {
  version = "0.2.3",
  targets = {
    all = {"updater.lua", "hq.lua", "launchcontrol.lua", "outpost.lua", "install.lua", "manifest.lua"},
    hq = {"updater.lua", "hq.lua", "manifest.lua"},
    silo = {"updater.lua", "launchcontrol.lua", "manifest.lua"},
    outpost = {"updater.lua", "outpost.lua", "manifest.lua"},
  },
}
