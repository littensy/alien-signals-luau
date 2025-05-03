local test = require("./suite").test
local signals = require("../src/lib")

local effect = signals.effect
local effectScope = signals.effectScope
local signal = signals.signal

test("should not trigger after stop", function()
	local count = signal(1)

	local triggers = 0

	local stopScope = effectScope(function()
		effect(function()
			triggers += 1
			count()
		end)
		assert(triggers == 1, "did not run initially")

		count(2)
		assert(triggers == 2, "did not run after update")
	end)

	count(3)
	assert(triggers == 3, "did not run after update outside scope")
	stopScope()
	count(4)
	assert(triggers == 3, "ran after stop")
end)

return {}
