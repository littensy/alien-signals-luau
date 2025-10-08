local signals = require("../src")

local computed = signals.computed
local setActiveSub = signals.setActiveSub
local signal = signals.signal

local function getFunctionName()
	local info = debug.info(2, "n")
	return info or "Unknown Test"
end

local function shouldPauseTracking()
	local src, setSrc = signal(0)

	local c = computed(function()
		local currentSub = setActiveSub(nil)
		local value = src()
		setActiveSub(currentSub)
		return value
	end)

	assert(c() == 0, getFunctionName())

	setSrc(1)
	assert(c() == 0, getFunctionName())
end

shouldPauseTracking()

return {}
