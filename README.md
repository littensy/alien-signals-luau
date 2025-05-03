# alien-signals-luau

A translation of [alien-signals](https://github.com/stackblitz/alien-signals) to Luau. Read more about the design on the source repository.

## Usage

#### Basic APIs

```luau
local signals = require("alien-signals")
local signal = signals.signal
local computed = signals.computed
local effect = signals.effect

local count = signal(1)
local doubleCount = computed(function()
    return count() * 2
end)

effect(function()
    print(`Count is: {count()}`)
end) -- print: "Count is: 1"

print(doubleCount()) -- 2

count(2) -- print: "Count is: 2"

print(doubleCount()) -- 4
```

#### Effect Scope

```luau
local signals = require("alien-signals")
local signal = signals.signal
local effect = signals.effect
local effectScope = signals.effectScope

local count = signal(1)

local stopScope = effectScope(function()
    effect(function()
        print(`Count in scope: {count()}`)
    end) -- print: "Count in scope: 1"
end)

count(2) -- print: "Count in scope: 2"

stopScope()

count(3) -- no print
```

## Tests

```bash
lune run tests
# or
lute tests/init.luau
```

## Benchmarks

```bash
lune run benchmarks/propagate
# or
lute benchmarks/propagate.luau
```
