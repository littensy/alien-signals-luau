export type ReactiveNode = {
	deps: Link?,
	depsTail: Link?,
	subs: Link?,
	subsTail: Link?,
	flags: ReactiveFlags,
}

export type Link = {
	dep: ReactiveNode,
	sub: ReactiveNode,
	prevSub: Link?,
	nextSub: Link?,
	prevDep: Link?,
	nextDep: Link?,
}

type Stack<T> = {
	value: T,
	prev: Stack<T>?,
}

export type ReactiveFlags = number

local NONE = 0b0000000
local MUTABLE = 0b0000001
local WATCHING = 0b0000010
local RECURSED_CHECK = 0b0000100
local RECURSED = 0b0001000
local DIRTY = 0b0010000
local PENDING = 0b0100000

local ReactiveFlags = {
	None = NONE,
	Mutable = MUTABLE,
	Watching = WATCHING,
	RecursedCheck = RECURSED_CHECK,
	Recursed = RECURSED,
	Dirty = DIRTY,
	Pending = PENDING,
}

local function createReactiveSystem(props: {
	update: (sub: ReactiveNode) -> boolean,
	notify: (sub: ReactiveNode) -> (),
	unwatched: (sub: ReactiveNode) -> (),
})
	local update = props.update
	local notify = props.notify
	local unwatched = props.unwatched

	local function isValidLink(checkLink: Link, sub: ReactiveNode): boolean
		local depsTail = sub.depsTail
		if depsTail then
			local link = sub.deps :: Link
			repeat
				if link == checkLink then
					return true
				end
				if link == depsTail then
					break
				end
				link = link.nextDep :: Link
			until not link
		end
		return false
	end

	local function link(dep: ReactiveNode, sub: ReactiveNode): ()
		local prevDep = sub.depsTail
		if prevDep and prevDep.dep == dep then
			return
		end
		local nextDep: Link?
		local recursedCheck = bit32.btest(sub.flags, RECURSED_CHECK)
		if recursedCheck then
			nextDep = if prevDep then prevDep.nextDep else sub.deps
			if nextDep and nextDep.dep == dep then
				sub.depsTail = nextDep
				return
			end
		end
		local prevSub = dep.subsTail
		if prevSub and prevSub.sub == sub and (not recursedCheck or isValidLink(prevSub, sub)) then
			return
		end
		local newLink: Link = {
			dep = dep,
			sub = sub,
			prevDep = prevDep,
			nextDep = nextDep,
			prevSub = prevSub,
		}
		sub.depsTail = newLink
		dep.subsTail = newLink
		if nextDep then
			nextDep.prevDep = newLink
		end
		if prevDep then
			prevDep.nextDep = newLink
		else
			sub.deps = newLink
		end
		if prevSub then
			prevSub.nextSub = newLink
		else
			dep.subs = newLink
		end
	end

	local function unlink(link: Link, sub: ReactiveNode?): Link?
		local sub = sub or link.sub
		local dep = link.dep
		local prevDep = link.prevDep
		local nextDep = link.nextDep
		local nextSub = link.nextSub
		local prevSub = link.prevSub
		if nextDep then
			nextDep.prevDep = prevDep
		else
			sub.depsTail = prevDep
		end
		if prevDep then
			prevDep.nextDep = nextDep
		else
			sub.deps = nextDep
		end
		if nextSub then
			nextSub.prevSub = prevSub
		else
			dep.subsTail = prevSub
		end
		if prevSub then
			prevSub.nextSub = nextSub
		else
			dep.subs = nextSub
			if not nextSub then
				unwatched(dep)
			end
		end
		return nextDep
	end

	local function propagate(link: Link): ()
		local next = link.nextSub
		local stack: Stack<Link?>?

		repeat
			local sub = link.sub

			local flags = sub.flags

			if bit32.btest(flags, bit32.bor(MUTABLE, WATCHING)) then
				if not bit32.btest(flags, bit32.bor(RECURSED_CHECK, RECURSED, DIRTY, PENDING)) then
					sub.flags = bit32.bor(flags, PENDING)
				elseif not bit32.btest(flags, bit32.bor(RECURSED_CHECK, RECURSED)) then
					flags = NONE
				elseif not bit32.btest(flags, RECURSED_CHECK) then
					sub.flags = bit32.bor(bit32.band(flags, bit32.bnot(RECURSED)), PENDING)
				elseif not bit32.btest(flags, bit32.bor(DIRTY, PENDING)) and isValidLink(link, sub) then
					sub.flags = bit32.bor(flags, bit32.bor(RECURSED, PENDING))
					flags = bit32.band(flags, MUTABLE)
				else
					-- selene: allow(if_same_then_else)
					flags = NONE
				end

				if bit32.btest(flags, WATCHING) then
					notify(sub)
				end

				if bit32.btest(flags, MUTABLE) then
					local subSubs = sub.subs
					if subSubs then
						link = subSubs
						if subSubs.nextSub then
							stack = { value = next, prev = stack }
							next = link.nextSub
						end
						continue
					end
				end
			end

			link = next :: Link

			if link then
				next = link.nextSub
				continue
			end

			local continueTop = false

			while stack do
				link = stack.value :: Link
				stack = stack.prev
				if link then
					next = link.nextSub
					continueTop = true
					break
				end
			end

			if continueTop then
				continue
			end

			break
		until false
	end

	local function startTracking(sub: ReactiveNode): ()
		sub.depsTail = nil
		sub.flags = bit32.bor(bit32.band(sub.flags, bit32.bnot(bit32.bor(RECURSED, DIRTY, PENDING))), RECURSED_CHECK)
	end

	local function endTracking(sub: ReactiveNode): ()
		local depsTail = sub.depsTail
		local toRemove = if depsTail then depsTail.nextDep else sub.deps
		while toRemove do
			toRemove = unlink(toRemove, sub)
		end
		sub.flags = bit32.band(sub.flags, bit32.bnot(RECURSED_CHECK))
	end

	local function shallowPropagate(link: Link): ()
		repeat
			local sub = link.sub
			local subFlags = sub.flags
			if bit32.band(subFlags, bit32.bor(PENDING, DIRTY)) == PENDING then
				sub.flags = bit32.bor(subFlags, DIRTY)
				if bit32.btest(subFlags, WATCHING) then
					notify(sub)
				end
			end
			link = link.nextSub :: Link
		until not link
	end

	local function checkDirty(link: Link, sub: ReactiveNode): boolean
		local stack: Stack<Link>?
		local checkDepth = 0

		repeat
			local dep = link.dep
			local depFlags = dep.flags

			local dirty = false

			if bit32.btest(sub.flags, DIRTY) then
				dirty = true
			elseif bit32.band(depFlags, bit32.bor(MUTABLE, DIRTY)) == bit32.bor(MUTABLE, DIRTY) then
				if update(dep) then
					local subs = dep.subs :: Link
					if subs.nextSub then
						shallowPropagate(subs)
					end
					dirty = true
				end
			elseif bit32.band(depFlags, bit32.bor(MUTABLE, PENDING)) == bit32.bor(MUTABLE, PENDING) then
				if link.nextSub or link.prevSub then
					stack = { value = link, prev = stack }
				end
				link = dep.deps :: Link
				sub = dep
				checkDepth += 1
				continue
			end

			if not dirty and link.nextDep then
				link = link.nextDep
				continue
			end

			local continueTop = false

			while checkDepth ~= 0 do
				checkDepth -= 1
				local firstSub = sub.subs :: Link
				local hasMultipleSubs = firstSub.nextSub ~= nil
				if hasMultipleSubs then
					link = (stack :: Stack<Link>).value
					stack = (stack :: Stack<Link>).prev
				else
					link = firstSub
				end
				if dirty then
					if update(sub) then
						if hasMultipleSubs then
							shallowPropagate(firstSub)
						end
						sub = link.sub
						continue
					end
				else
					sub.flags = bit32.band(sub.flags, bit32.bnot(PENDING))
				end
				sub = link.sub
				if link.nextDep then
					link = link.nextDep
					continueTop = true
					break
				end
				dirty = false
			end

			if continueTop then
				continue
			end

			return dirty
		until false
	end

	return {
		link = link,
		unlink = unlink,
		propagate = propagate,
		checkDirty = checkDirty,
		endTracking = endTracking,
		startTracking = startTracking,
		shallowPropagate = shallowPropagate,
	}
end

return {
	ReactiveFlags = ReactiveFlags,
	createReactiveSystem = createReactiveSystem,
}
