local system = require("@self/system")

local createReactiveSystem = system.createReactiveSystem
local SubscriberFlags = system.SubscriberFlags

type Subscriber = system.Subscriber
type Dependency = system.Dependency
type SubscriberFlags = system.SubscriberFlags

local Computed = SubscriberFlags.Computed
local Effect = SubscriberFlags.Effect
local Dirty = SubscriberFlags.Dirty
local PendingComputed = SubscriberFlags.PendingComputed
local PendingEffect = SubscriberFlags.PendingEffect

type EffectScope = {
	isScope: true,
} & Subscriber

type Effect = {
	fn: () -> (),
} & Subscriber & Dependency

type Signal<T> = {
	currentValue: T,
} & Dependency

type Computed<T> = {
	getter: (previousValue: T?) -> T,
} & Signal<T?> & Subscriber

local batchDepth = 0
local activeSub: Subscriber?
local activeScope: EffectScope?

local reactive: typeof(createReactiveSystem(function() end, function() end)) = {}
local startTracking = reactive.startTracking
local endTracking = reactive.endTracking
local updateDirtyFlag = reactive.updateDirtyFlag
local processPendingInnerEffects = reactive.processPendingInnerEffects

local function notifyEffect(e: Effect): boolean
	local flags = e.flags
	if bit32.band(flags, Dirty) ~= 0 or (bit32.band(flags, PendingComputed) ~= 0 and updateDirtyFlag(e, flags)) then
		local prevSub = activeSub
		activeSub = e
		startTracking(e)
		local success, error = pcall(e.fn)
		activeSub = prevSub
		endTracking(e)
		if not success then
			error(error)
		end
	else
		processPendingInnerEffects(e, e.flags)
	end
	return true
end

local function notifyEffectScope(e: EffectScope): boolean
	local flags = e.flags
	if bit32.band(flags, PendingEffect) ~= 0 then
		processPendingInnerEffects(e, e.flags)
		return true
	end
	return false
end

local function effectStop(this: Subscriber): () -> ()
	return function()
		startTracking(this)
		endTracking(this)
	end
end

local function updateComputed<T>(computed: Computed<T>): boolean
	local prevSub = activeSub
	activeSub = computed
	startTracking(computed)

	local oldValue = computed.currentValue
	local success, newValue = pcall(computed.getter, oldValue)
	activeSub = prevSub
	endTracking(computed)
	if not success then
		error(newValue)
	end
	local result = false
	if newValue ~= oldValue then
		computed.currentValue = newValue
		result = true
	end
	return result
end

local function notify(e: Effect | EffectScope)
	if e.isScope then
		return notifyEffectScope(e)
	else
		return notifyEffect(e)
	end
end

reactive = createReactiveSystem(updateComputed, notify)

startTracking = reactive.startTracking
endTracking = reactive.endTracking
updateDirtyFlag = reactive.updateDirtyFlag
processPendingInnerEffects = reactive.processPendingInnerEffects
local link = reactive.link
local propagate = reactive.propagate
local processEffectNotifications = reactive.processEffectNotifications
local processComputedUpdate = reactive.processComputedUpdate

local function computedGetter<T>(this: Computed<T>): () -> T
	return function()
		local flags = this.flags
		if bit32.band(flags, bit32.bor(Dirty, PendingComputed)) ~= 0 then
			processComputedUpdate(this, flags)
		end
		if activeSub then
			link(this, activeSub)
		elseif activeScope then
			link(this, activeScope)
		end
		return this.currentValue
	end
end

local function signalGetterSetter<T>(this: Signal<T>): (() -> T?, (value: T) -> ())
	local function getter(): T?
		if activeSub then
			link(this, activeSub)
		end
		return this.currentValue
	end

	local function setter(value)
		if this.currentValue ~= value then
			this.currentValue = value
			local subs = this.subs
			if subs then
				propagate(subs)
				if batchDepth == 0 then
					processEffectNotifications()
				end
			end
		end
	end

	return getter, setter
end

local pauseStack: { Subscriber? } = {}

local function startBatch()
	batchDepth += 1
end

local function endBatch()
	batchDepth -= 1
	if batchDepth == 0 then
		processEffectNotifications()
	end
end

local function pauseTracking()
	table.insert(pauseStack, activeSub)
	activeSub = nil
end

local function resumeTracking()
	activeSub = table.remove(pauseStack)
end

local function signal<T>(intialValue: T?): (() -> T?, (value: T?) -> ())
	return signalGetterSetter({
		currentValue = intialValue,
	})
end

local function computed<T>(getter: (previousValue: T?) -> T): () -> T
	return computedGetter({
		flags = bit32.bor(Computed, Dirty),
		getter = getter,
	})
end

local function effect<T>(fn: () -> T): () -> ()
	local e: Effect = {
		fn = fn,
		flags = Effect,
	}
	if activeSub then
		link(e, activeSub)
	elseif activeScope then
		link(e, activeScope)
	end
	local prevSub = activeSub
	activeSub = e
	local success, error = pcall(e.fn)
	activeSub = prevSub
	if not success then
		error(error)
	end
	return effectStop(e)
end

local function effectScope<T>(fn: () -> T): () -> ()
	local e: EffectScope = {
		flags = Effect,
		isScope = true,
	}
	local prevSub = activeScope
	activeScope = e
	local success, error = pcall(fn)
	activeScope = prevSub
	if not success then
		error(error)
	end
	return effectStop(e)
end

return {
	batchDepth = batchDepth,
	startBatch = startBatch,
	endBatch = endBatch,
	pauseTracking = pauseTracking,
	resumeTracking = resumeTracking,
	signal = signal,
	computed = computed,
	effect = effect,
	effectScope = effectScope,
	createReactiveSystem = createReactiveSystem,
	SubscriberFlags = SubscriberFlags,
}
