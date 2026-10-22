--!strict
-- TypeTorch Studio plugin: attaches Studio to `typetorch serve` by itself and keeps it synced (see README.md).
-- Only as a plugin: a copy of this model inside a place (inserted or synced in) runs as a plain Script with no
-- `plugin`, and must do nothing there.
if typeof(plugin) ~= "Instance" then
	warn(`TypeTorch: {script:GetFullName()} is a copy of the TypeTorch Studio plugin inside the place; it does nothing here. Delete it (the plugin itself lives in Studio's Plugins folder).`)
	return
end

local App = require(script.Parent.TypeTorch.App)

App.start(plugin)
