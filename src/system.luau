export type Dependency = {
	subs: Link?,
	subsTail: Link?,
}

export type Subscriber = {
	flags: SubscriberFlags,
	deps: Link?,
	depsTail: Link?,
}

export type Link = {
	dep: Dependency | (Dependency & Subscriber),
	sub: Subscriber | (Dependency & Subscriber),
	prevSub: Link?,
	nextSub: Link?,
	nextDep: Link?,
}

type OneWayLink<T> = {
	target: T,
	linked: OneWayLink<T>?,
}

export type SubscriberFlags = number

local Computed = 0b00000001
local Effect = 0b00000010
local Tracking = 0b00000100
local Notified = 0b00001000
local Recursed = 0b00010000
local Dirty = 0b00100000
local PendingComputed = 0b01000000
local PendingEffect = 0b10000000
local Propagated = 0b11100000

local SubscriberFlags = {
	Computed = Computed,
	Effect = Effect,
	Tracking = Tracking,
	Notified = Notified,
	Recursed = Recursed,
	Dirty = Dirty,
	PendingComputed = PendingComputed,
	PendingEffect = PendingEffect,
	Propagated = Propagated,
}

local function createReactiveSystem(
	updateComputed: (computed: Dependency & Subscriber) -> boolean,
	notifyEffect: (effect: Subscriber) -> boolean
)
	local notifyBuffer: { Subscriber? } = {}
	local notifyBufferIndex = 1
	local notifyBufferLength = 0

	local function linkNewDep(dep: Dependency, sub: Subscriber, nextDep: Link?, depsTail: Link?): Link
		local newLink: Link = {
			dep = dep,
			sub = sub,
			nextDep = nextDep,
		}
		if depsTail == nil then
			sub.deps = newLink
		else
			depsTail.nextDep = newLink
		end
		if dep.subs == nil then
			dep.subs = newLink
		else
			local oldTail = dep.subsTail
			newLink.prevSub = oldTail
			oldTail.nextSub = newLink
		end
		sub.depsTail = newLink
		dep.subsTail = newLink
		return newLink
	end

	local function isValidLink(checkLink: Link, sub: Subscriber): boolean
		local depsTail = sub.depsTail
		if depsTail then
			local link = sub.deps
			repeat
				if link == checkLink then
					return true
				end
				if link == depsTail then
					break
				end
				link = (link :: typeof(sub.deps)).nextDep
			until link == nil
		end
		return false
	end

	local function createLink(dep: Dependency, sub: Subscriber): Link?
		local currentDep = sub.depsTail
		if currentDep and currentDep.dep == dep then
			return
		end
		local nextDep = if currentDep then currentDep.nextDep else sub.deps
		if nextDep and nextDep.dep == dep then
			sub.depsTail = nextDep
			return
		end
		local depLastSub = dep.subsTail
		if depLastSub and depLastSub.sub == sub and isValidLink(depLastSub, sub) then
			return
		end
		return linkNewDep(dep, sub, nextDep, currentDep)
	end

	local function propagate(current: Link)
		local next = current.nextSub
		local branches: OneWayLink<Link?>?
		local branchDepth = 0
		local targetFlag = Dirty

		while true do
			local sub = current.sub
			local subFlags = sub.flags

			local shouldNotify = false

			if bit32.band(subFlags, bit32.bor(Tracking, Recursed, Propagated)) == 0 then
				sub.flags = bit32.bor(subFlags, targetFlag, Notified)
				shouldNotify = true
			elseif bit32.band(subFlags, Recursed) ~= 0 and bit32.band(subFlags, Tracking) == 0 then
				sub.flags = bit32.bor(bit32.band(subFlags, bit32.bnot(Recursed)), targetFlag, Notified)
				shouldNotify = true
			elseif bit32.band(subFlags, Propagated) == 0 and isValidLink(current, sub) then
				sub.flags = bit32.bor(subFlags, Recursed, targetFlag, Notified)
				shouldNotify = (sub :: Dependency).subs ~= nil
			end

			if shouldNotify then
				local subSubs = (sub :: Dependency).subs
				if subSubs then
					current = subSubs
					if subSubs.nextSub then
						branches = { target = next, linked = branches }
						branchDepth += 1
						next = current.nextSub
						targetFlag = PendingComputed
					else
						targetFlag = if bit32.band(subFlags, Effect) ~= 0 then PendingEffect else PendingComputed
					end
					continue
				end
				if bit32.band(subFlags, Effect) ~= 0 then
					notifyBufferLength += 1
					notifyBuffer[notifyBufferLength] = sub
				end
			elseif bit32.band(subFlags, bit32.bor(Tracking, targetFlag)) == 0 then
				sub.flags = bit32.bor(subFlags, targetFlag, Notified)
				if bit32.band(subFlags, bit32.bor(Effect, Notified)) == Effect then
					notifyBufferLength += 1
					notifyBuffer[notifyBufferLength] = sub
				end
			elseif
				bit32.band(subFlags, targetFlag) == 0
				and bit32.band(subFlags, Propagated) ~= 0
				and isValidLink(current, sub)
			then
				sub.flags = bit32.bor(subFlags, targetFlag)
			end

			current = next

			if current then
				next = current.nextSub
				targetFlag = if branchDepth > 0 then PendingComputed else Dirty
				continue
			end

			local shouldContinue = false

			while branchDepth > 0 do
				branchDepth -= 1
				current = (branches :: OneWayLink<Link?>).target
				branches = (branches :: OneWayLink<Link?>).linked
				if current then
					next = current.nextSub
					targetFlag = if branchDepth > 0 then PendingComputed else Dirty
					shouldContinue = true
					break
				end
			end

			if shouldContinue then
				continue
			end

			break
		end
	end

	local function startTracking(sub: Subscriber)
		sub.depsTail = nil
		sub.flags = bit32.bor(bit32.band(sub.flags, bit32.bnot(bit32.bor(Notified, Recursed, Propagated))), Tracking)
	end

	local function clearTracking(link: Link)
		repeat
			local dep = link.dep
			local nextDep = link.nextDep
			local nextSub = link.nextSub
			local prevSub = link.prevSub

			if nextSub then
				nextSub.prevSub = prevSub
			else
				dep.subsTail = prevSub
			end

			if prevSub then
				prevSub.nextSub = nextSub
			else
				dep.subs = nextSub
			end

			if dep.subs == nil and dep.deps then
				local depFlags = dep.flags
				if bit32.band(depFlags, Dirty) == 0 then
					dep.flags = bit32.bor(depFlags, Dirty)
				end
				local depDeps = dep.deps
				if depDeps then
					link = depDeps
					dep.depsTail.nextDep = nextDep
					dep.deps = nil
					dep.depsTail = nil
					continue
				end
			end
			link = nextDep
		until link == nil
	end

	local function endTracking(sub: Subscriber)
		local depsTail = sub.depsTail
		if depsTail then
			local nextDep = depsTail.nextDep
			if nextDep then
				clearTracking(nextDep)
				depsTail.nextDep = nil
			end
		elseif sub.deps then
			clearTracking(sub.deps)
			sub.deps = nil
		end
		sub.flags = bit32.band(sub.flags, bit32.bnot(Tracking))
	end

	local function shallowPropagate(link: Link)
		repeat
			local sub = link.sub
			local subFlags = sub.flags
			if bit32.band(subFlags, bit32.bor(PendingComputed, Dirty)) == PendingComputed then
				sub.flags = bit32.bor(subFlags, Dirty, Notified)
				if bit32.band(subFlags, bit32.bor(Effect, Notified)) == Effect then
					notifyBufferLength += 1
					notifyBuffer[notifyBufferLength] = sub
				end
			end
			link = link.nextSub
		until link == nil
	end

	local function checkDirty(current: Link): boolean
		local prevLinks: OneWayLink<Link>?
		local checkDepth = 0
		local dirty: boolean

		while true do
			dirty = false
			local dep = current.dep

			if bit32.band(current.sub.flags, Dirty) ~= 0 then
				dirty = true
			elseif dep.flags then
				local depFlags = dep.flags
				if bit32.band(depFlags, bit32.bor(Computed, Dirty)) == bit32.bor(Computed, Dirty) then
					if updateComputed(dep) then
						local subs = dep.subs
						if subs.nextSub then
							shallowPropagate(subs)
						end
						dirty = true
					end
				elseif
					bit32.band(depFlags, bit32.bor(Computed, PendingComputed)) == bit32.bor(Computed, PendingComputed)
				then
					if current.nextSub or current.prevSub then
						prevLinks = { target = current, linked = prevLinks }
					end
					current = dep.deps
					checkDepth += 1
					continue
				end
			end

			if not dirty and current.nextDep then
				current = current.nextDep
				continue
			end

			local shouldContinue = false

			while checkDepth > 0 do
				checkDepth -= 1
				local sub = current.sub :: Dependency & Subscriber
				local firstSub = sub.subs
				if dirty then
					if updateComputed(sub) then
						if firstSub.nextSub then
							current = (prevLinks :: OneWayLink<Link>).target
							prevLinks = (prevLinks :: OneWayLink<Link>).linked
							shallowPropagate(firstSub)
						else
							current = firstSub
						end
						continue
					end
				else
					sub.flags = bit32.band(sub.flags, bit32.bnot(PendingComputed))
				end
				if firstSub.nextSub then
					current = (prevLinks :: OneWayLink<Link>).target
					prevLinks = (prevLinks :: OneWayLink<Link>).linked
				else
					current = firstSub
				end
				if current.nextDep then
					current = current.nextDep
					shouldContinue = true
					break
				end

				dirty = false
			end

			if shouldContinue then
				continue
			end

			return dirty
		end
	end

	local function updateDirtyFlag(sub: Subscriber, flags: SubscriberFlags): boolean
		if checkDirty(sub.deps) then
			sub.flags = bit32.bor(flags, Dirty)
			return true
		else
			sub.flags = bit32.band(flags, bit32.bnot(PendingComputed))
			return false
		end
	end

	local function processComputedUpdate(computed: Dependency & Subscriber, flags: SubscriberFlags)
		if bit32.band(flags, Dirty) ~= 0 or checkDirty(computed.deps) then
			if updateComputed(computed) then
				local subs = computed.subs
				if subs then
					shallowPropagate(subs)
				end
			end
		else
			computed.flags = bit32.band(flags, bit32.bnot(PendingComputed))
		end
	end

	local function processPendingInnerEffects(sub: Subscriber, flags: SubscriberFlags)
		if bit32.band(flags, PendingEffect) ~= 0 then
			sub.flags = bit32.band(flags, bit32.bnot(PendingEffect))
			local link = sub.deps
			repeat
				local dep = (link :: typeof(sub.deps)).dep
				if dep.flags and bit32.band(dep.flags, Effect) ~= 0 and bit32.band(dep.flags, Propagated) ~= 0 then
					notifyEffect(dep)
				end
				link = (link :: typeof(sub.deps)).nextDep
			until link == nil
		end
	end

	local function processEffectNotifications()
		while notifyBufferIndex <= notifyBufferLength do
			local effect = notifyBuffer[notifyBufferIndex]
			notifyBuffer[notifyBufferIndex] = nil
			notifyBufferIndex += 1
			if not notifyEffect(effect) then
				effect.flags = bit32.band(effect.flags, bit32.bnot(Notified))
			end
		end
		notifyBufferIndex = 1
		notifyBufferLength = 0
	end

	return {
		link = createLink,
		propagate = propagate,
		updateDirtyFlag = updateDirtyFlag,
		startTracking = startTracking,
		endTracking = endTracking,
		processEffectNotifications = processEffectNotifications,
		processComputedUpdate = processComputedUpdate,
		processPendingInnerEffects = processPendingInnerEffects,
	}
end

return {
	createReactiveSystem = createReactiveSystem,
	SubscriberFlags = SubscriberFlags,
}
