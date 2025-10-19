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
	currentValue: T,
	pendingValue: T,
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
	local dep = if depsTail then depsTail.nextDep else sub.deps
	while dep do
		dep = unlink(dep, sub)
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

local function updateSignal(s: Signal): boolean
	s.flags = MUTABLE
	local pendingValue = s.pendingValue
	if s.currentValue ~= pendingValue then
		s.currentValue = pendingValue
		return true
	else
		return false
	end
end

local function signalGetterSetter<T>(this: Signal<T>): (() -> T, (value: T) -> ())
	local function getter(): T
		if bit32.btest(this.flags, DIRTY) then
			if updateSignal(this) then
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
		return this.currentValue
	end

	local function setter(value: T)
		if this.pendingValue ~= value then
			this.pendingValue = value
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
		end
		if activeSub then
			link(this, activeSub, cycle)
		end
		return this.value :: T
	end
end

local function effectScopeStop(this: EffectScope): () -> ()
	return function()
		this.depsTail = nil
		this.flags = NONE
		purgeDeps(this)
		local sub = this.subs
		if sub then
			unlink(sub, this)
		end
	end
end

local function effectStop(this: Effect): () -> ()
	return effectScopeStop(this)
end

local function signal<T>(initialValue: T): (() -> T, (value: T) -> ())
	return signalGetterSetter({
		currentValue = initialValue,
		pendingValue = initialValue,
		flags = MUTABLE,
	})
end

local function computed<T>(getter: (previousValue: T?) -> T): () -> T
	return computedGetter({
		flags = bit32.bor(MUTABLE, DIRTY),
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

local function update(node: ReactiveNode): boolean
	if node.depsTail then
		return updateComputed(node :: Computed)
	else
		return updateSignal(node :: Signal)
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

local function unwatched(node: ReactiveNode)
	if bit32.band(node.flags, MUTABLE) == 0 then
		effectScopeStop(node)()
	elseif node.depsTail then
		node.depsTail = nil
		node.flags = bit32.bor(MUTABLE, DIRTY)
		purgeDeps(node)
	end
end

local reactiveSystem = createReactiveSystem({
	update = update,
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
