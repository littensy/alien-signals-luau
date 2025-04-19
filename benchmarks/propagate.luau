local signals = require("../src")
local bench = require("./bench")

local computed = signals.computed
local effect = signals.effect
local signal = signals.signal

local dimensions = { 1, 10, 100 }

for _, w in dimensions do
	for _, h in dimensions do
		bench(`propagate: {w} * {h}`, function()
			local src, setSrc = signal(1)
			for _ = 1, w do
				local last = src
				for _ = 1, h do
					local prev = last
					last = computed(function()
						return prev() + 1
					end)
				end
				effect(function()
					last()
				end)
			end
			setSrc(src() + 1)
		end)
	end
end
