local signals = require("../src/lib")
local bench = require("./bench")

local computed = signals.computed
local effect = signals.effect
local signal = signals.signal

local dimensions = { 1, 10, 100 }

for _, w in dimensions do
	for _, h in dimensions do
		bench(`propagate: {w} * {h}`, function()
			local src = signal({ w = w, h = h } :: { [string]: any })
			for i = 1, w do
				local last = src
				for j = 1, h do
					local prev = last
					last = computed(function()
						return {
							[`{i}-{j}`] = prev(),
						}
					end)
				end
				effect(function()
					last()
				end)
			end
			src({ upstream = src() })
		end)
	end
end
