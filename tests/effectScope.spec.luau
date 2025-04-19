local signals = require("../src")

local effect = signals.effect
local effectScope = signals.effectScope
local signal = signals.signal

local function getFunctionName()
	return debug.info(2, "n")
end

local function shouldNotTriggerAfterStop()
	local getCount, setCount = signal(1)

	local triggers = 0
	local effect1

	local stopScope = effectScope(function()
		effect1 = effect(function()
			triggers += 1
			getCount()
		end)
		assert(triggers == 1, getFunctionName())

		setCount(2)
		assert(triggers == 2, getFunctionName())
	end)

	setCount(3)
	assert(triggers == 3, getFunctionName())
	stopScope()
	setCount(4)
	assert(triggers == 3, getFunctionName())
end

shouldNotTriggerAfterStop()

return {}
