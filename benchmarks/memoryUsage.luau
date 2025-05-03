local signals = require("../src/lib")

local computed = signals.computed
local effect = signals.effect
local signal = signals.signal

local function from<T>(amount: number, fn: (i: number) -> T): { T }
	local result = table.create(amount)
	for i = 1, amount do
		result[i] = fn(i)
	end
	return result
end

local start = gcinfo()

local signals = from(10000, function()
	return signal(0)
end)

local finish = gcinfo()

print(`signal: {finish - start} KB`)

start = finish

local computeds = from(10000, function(i)
	return computed(function()
		return signals[i]() + 1
	end)
end)

finish = gcinfo()

print(`computed: {finish - start} KB`)

start = finish

from(10000, function(i)
	return effect(function()
		return computeds[i]()
	end)
end)

finish = gcinfo()

print(`effect: {finish - start} KB`)

start = finish

local w = 100
local h = 100
local src = signal(1)

for _ = 1, w do
	local last = src
	for _ = 1, h do
		local prev = last
		last = computed(function()
			return prev() + 1
		end)
		effect(function()
			last()
		end)
	end
end

src(src() + 1)

finish = gcinfo()

print(`tree: {finish - start} KB`)
