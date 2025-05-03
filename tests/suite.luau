local results: { string } = {}
local stack: { string } = {}
local errors: { string } = {}
local tests = 0

local function log(result: string, index: number?)
	local index = index or #results + 1
	local indent = string.rep("  ", #stack - 1)

	results[index] = indent .. result
end

local function test(name: string, callback: () -> ())
	tests += 1
	table.insert(stack, name)

	local success = xpcall(callback, function(err)
		local path = table.concat(stack, " > ")
		table.insert(errors, `\n🔴 {path}:\n{err}`)
	end)

	if not success then
		log(`🔴 {name}`)
	end

	table.remove(stack)
end

local function describe(name: string, callback: () -> ())
	table.insert(stack, name)
	table.insert(results, name)

	local index = #results
	local errorCount = #errors
	callback()

	if #errors > errorCount then
		log(`🔴 {name}`, index)
	else
		log(`🟢 {name}`, index)
	end

	table.remove(stack)
end

local function finish()
	if #errors == 0 then
		print(`\n🔵 {tests} tests passed\n`)
		return
	end

	print(`\n🔵 {tests - #errors} / {tests} tests passed\n`)

	for _, result in results do
		print(result)
	end

	print()
	error(`{#errors} test(s) failed:\n{table.concat(errors, "\n")}\n`)
end

return {
	test = test,
	describe = describe,
	finish = finish,
}
