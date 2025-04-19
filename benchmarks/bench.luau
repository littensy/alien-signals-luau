return function(name: string, test: () -> ())
	local start = os.clock()
	local iter = 0
	while os.clock() - start < 2 do
		iter += 1
		test()
	end
	local endTime = os.clock()
	local elapsed = endTime - start
	print(`{name}: {elapsed / iter * 1000 * 1000} us/iter`)
end
