local atom = require("./atom")
local computed = require("./computed")
local effect = require("./effect")
local mapped = require("./mapped")
local observe = require("./observe")
local store = require("./store")
local subscribe = require("./subscribe")
local types = require("./types")

export type Atom<State> = types.Atom<State>
export type Selector<State> = types.Selector<State>
export type Molecule<State> = types.Selector<State>
export type SyncPayload = types.SyncPayload

return {
	atom = atom,
	computed = computed,
	effect = effect,
	mapped = mapped,
	observe = observe,
	subscribe = subscribe,
	batch = store.batch,
	capture = store.capture,
	isAtom = store.isAtom,
	notify = store.notify,
	peek = store.peek,
}
