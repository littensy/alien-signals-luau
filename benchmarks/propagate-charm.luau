local charm = require("../charm")
local bench = require("./bench")

local computed = charm.computed
local effect = charm.effect
local signal = charm.atom

local dimensions = { 1, 10, 100 }

for _, w in dimensions do
	for _, h in dimensions do
		bench(`propagate: {w} * {h}`, function()
			local src = signal(1)
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
			src(src() + 1)
		end)
	end
end
