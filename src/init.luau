local system = require("@self/system")

export type ReactiveFlags = system.ReactiveFlags
export type ReactiveNode = system.ReactiveNode
export type Link = system.Link

local ReactiveFlags = system.ReactiveFlags
local createReactiveSystem = system.createReactiveSystem

local NONE = 0b0000000
local MUTABLE = 0b0000001
local WATCHING = 0b0000010
local RECURSED_CHECK = 0b0000100
local DIRTY = 0b0010000
local PENDING = 0b0100000
local QUEUED = 0b1000000

type EffectScope = ReactiveNode

type Effect = ReactiveNode & {
	fn: () -> (),
}

type Computed<T = any> = ReactiveNode & {
	value: T?,
	getter: (previousValue: T?) -> T,
}

type Signal<T = any> = ReactiveNode & {
	previousValue: T,
	value: T,
}

local link: (dep: ReactiveNode, sub: ReactiveNode, version: number) -> ()
local unlink: (link: Link, sub: ReactiveNode?) -> Link?
local propagate: (link: Link) -> ()
local checkDirty: (link: Link, sub: ReactiveNode) -> boolean
local shallowPropagate: (link: Link) -> ()

local cycle = 0
local batchDepth = 0
local notifyIndex = 0
local queuedEffects: { Effect | EffectScope? } = {}
local queuedEffectsLength = 0
local activeSub: ReactiveNode?

local function getActiveSub(): ReactiveNode?
	return activeSub
end

local function setActiveSub(sub: ReactiveNode?)
	local prevSub = activeSub
	activeSub = sub
	return prevSub
end

local function purgeDeps(sub: ReactiveNode)
	local depsTail = sub.depsTail
	local toRemove = if depsTail then depsTail.nextDep else sub.deps
	while toRemove do
		toRemove = unlink(toRemove, sub)
	end
end

local function setNotPending(sub: ReactiveNode, flags: ReactiveFlags)
	sub.flags = bit32.band(flags, bit32.bnot(PENDING))
end

local function run(e: Effect | EffectScope, flags: ReactiveFlags): ()
	if
		bit32.btest(flags, DIRTY)
		or (bit32.btest(flags, PENDING) and (checkDirty(e.deps :: Link, e) or setNotPending(e, flags)))
	then
		local e = e :: Effect
		cycle += 1
		e.depsTail = nil
		e.flags = bit32.bor(WATCHING, RECURSED_CHECK)
		local prevSub = setActiveSub(e)
		local success, result: unknown = pcall(e.fn)
		activeSub = prevSub
		e.flags = bit32.band(e.flags, bit32.bnot(RECURSED_CHECK))
		purgeDeps(e)
		if not success then
			error(result)
		end
	else
		local link = e.deps
		while link do
			local dep = link.dep
			local depFlags = dep.flags
			if bit32.btest(depFlags, QUEUED) then
				depFlags = bit32.band(depFlags, bit32.bnot(QUEUED))
				dep.flags = depFlags
				run(dep, depFlags)
			end
			link = link.nextDep
		end
	end
end

local function flush(): ()
	while notifyIndex < queuedEffectsLength do
		notifyIndex += 1
		local effect = queuedEffects[notifyIndex] :: Effect
		queuedEffects[notifyIndex] = nil
		effect.flags = bit32.band(effect.flags, bit32.bnot(QUEUED))
		run(effect, effect.flags)
	end
	notifyIndex = 0
	queuedEffectsLength = 0
end

local function getBatchDepth(): number
	return batchDepth
end

local function startBatch()
	batchDepth += 1
end

local function endBatch()
	batchDepth -= 1
	if batchDepth == 0 then
		flush()
	end
end

local function updateComputed(c: Computed): boolean
	cycle += 1
	c.depsTail = nil
	c.flags = bit32.bor(MUTABLE, RECURSED_CHECK)
	local prevSub = setActiveSub(c)
	local oldValue = c.value
	local success, result: unknown = pcall(c.getter, oldValue)
	activeSub = prevSub
	c.flags = bit32.band(c.flags, bit32.bnot(RECURSED_CHECK))
	purgeDeps(c)
	if not success then
		error(result)
	end
	if oldValue ~= result then
		c.value = result
		return true
	else
		return false
	end
end

local function updateSignal(s: Signal, value: any): boolean
	s.flags = MUTABLE
	if s.previousValue ~= value then
		s.previousValue = value
		return true
	else
		return false
	end
end

local function signalGetterSetter<T>(this: Signal<T>): (() -> T, (value: T) -> ())
	local function getter(): T
		local value = this.value
		if bit32.btest(this.flags, DIRTY) then
			if updateSignal(this, value) then
				local subs = this.subs
				if subs then
					shallowPropagate(subs)
				end
			end
		end
		local sub = activeSub
		while sub do
			if bit32.btest(sub.flags, bit32.bor(MUTABLE, WATCHING)) then
				link(this, sub, cycle)
				break
			end
			local subs = sub.subs
			if subs then
				sub = subs.sub
			end
		end
		return value
	end

	local function setter(newValue: T)
		if this.value ~= newValue then
			this.value = newValue
			this.flags = bit32.bor(MUTABLE, DIRTY)
			local subs = this.subs
			if subs then
				propagate(subs)
				if batchDepth == 0 then
					flush()
				end
			end
		end
	end

	return getter, setter
end

local function computedGetter<T>(this: Computed<T>): () -> T
	return function()
		local flags = this.flags
		if
			bit32.btest(flags, DIRTY)
			or (bit32.btest(flags, PENDING) and (checkDirty(this.deps :: Link, this) or setNotPending(this, flags)))
		then
			if updateComputed(this) then
				local subs = this.subs
				if subs then
					shallowPropagate(subs)
				end
			end
		elseif flags == NONE then
			this.flags = MUTABLE
			local prevSub = setActiveSub(this)
			local success, result: unknown = pcall(this.getter, this.value)
			activeSub = prevSub
			if not success then
				error(result)
			end
			this.value = result :: T
		end
		if activeSub then
			link(this, activeSub, cycle)
		end
		return this.value :: T
	end
end

local function effectScopeStop(this: EffectScope): () -> ()
	return function()
		local dep = this.deps
		while dep do
			dep = unlink(dep, this)
		end
		local sub = this.subs
		if sub then
			unlink(sub)
		end
	end
end

local function effectStop(this: Effect): () -> ()
	local stopEffectScope = effectScopeStop(this)
	return function()
		stopEffectScope()
		this.flags = NONE
	end
end

local function signal<T>(initialValue: T): (() -> T, (value: T) -> ())
	return signalGetterSetter({
		previousValue = initialValue,
		value = initialValue,
		flags = MUTABLE,
	})
end

local function computed<T>(getter: (previousValue: T?) -> T): () -> T
	return computedGetter({
		flags = NONE,
		getter = getter,
	})
end

local function effect(fn: () -> ()): () -> ()
	local e: Effect = {
		fn = fn,
		flags = WATCHING,
	}
	local prevSub = setActiveSub(e)
	if prevSub then
		link(e, prevSub, 0)
	end
	local success, result: unknown = pcall(fn)
	activeSub = prevSub
	if not success then
		error(result)
	end
	return effectStop(e)
end

local function effectScope(fn: () -> ()): () -> ()
	local e: EffectScope = {
		flags = NONE,
	}
	local prevSub = setActiveSub(e)
	if prevSub then
		link(e, prevSub, 0)
	end
	local success, result: unknown = pcall(fn)
	activeSub = prevSub
	if not success then
		error(result)
	end
	return effectScopeStop(e)
end

local function update(signal: Signal | Computed): boolean
	if (signal :: Computed).getter then
		return updateComputed(signal :: Computed)
	else
		return updateSignal(signal :: Signal, signal.value)
	end
end

local function notify(e: Effect | EffectScope)
	local flags = e.flags
	if not bit32.btest(flags, QUEUED) then
		(e :: Effect).flags = bit32.bor(flags, QUEUED)
		local subs = e.subs
		if subs then
			notify(subs.sub)
		else
			queuedEffectsLength += 1
			queuedEffects[queuedEffectsLength] = e
		end
	end
end

local function unwatched(node: Signal | Computed | Effect | EffectScope)
	if (node :: Computed).getter then
		local toRemove = node.deps
		if toRemove then
			(node :: Computed).flags = bit32.bor(MUTABLE, DIRTY)
			repeat
				toRemove = unlink(toRemove, node)
			until not toRemove
		end
	elseif (node :: Effect).fn then
		effectStop(node :: Effect)()
	elseif (node :: Signal).previousValue == nil then
		effectScopeStop(node)()
	end
end

local reactiveSystem = createReactiveSystem({
	update = update :: (ReactiveNode) -> boolean,
	notify = notify,
	unwatched = unwatched,
})

link = reactiveSystem.link
unlink = reactiveSystem.unlink
propagate = reactiveSystem.propagate
checkDirty = reactiveSystem.checkDirty
shallowPropagate = reactiveSystem.shallowPropagate

return {
	ReactiveFlags = ReactiveFlags,
	createReactiveSystem = createReactiveSystem,
	getActiveSub = getActiveSub,
	setActiveSub = setActiveSub,
	getBatchDepth = getBatchDepth,
	startBatch = startBatch,
	endBatch = endBatch,
	signal = signal,
	computed = computed,
	effect = effect,
	effectScope = effectScope,
}
