## Component: Redstone in Motion
This component represents a Carriage Controller block from the [Redstone in Motion](https://www.curseforge.com/minecraft/mc-mods/remain-in-motion) mod.

~~**Important**: this component is only available if OpenComponents is also installed!~~
Contents of OpenComponents have already been added into OpenComputers.

Component name: `carriage`.

Callbacks:

- `getAnchored(): boolean`
Gets whether the controller should remain where it is when moving a carriage.
- `setAnchored(value: boolean): boolean`
Sets whether the controller should remain where it is when moving a carriage. Returns the new value.
- `move(direction: string or number[, simulate: boolean]): boolean`
Tells the controller to try to move a carriage. The direction can either be a string indicating a direction or one of the [sides API](../api/sides.md) constants. You can optionally specify whether to only simulate a move, which defaults to false. Returns `true` if the command was relayed successfully.
This function does not return the actual results of the move.
Due to technical limitations the results are asynchronously fed back to the computer as a signal with the name `carriage_moved`. It has the signature success: `result[, reason: string]`, where `reason` is an error string if the move failed. This is because the computer that triggers the move may be moved as well, meaning it has to be persisted, which is only possible while it is in a yielded state.
Possible string values for direction are: negy, posy, negz, posz, negx, posx and down, up, north, south, west, east.

- `simulate(direction: string or number): boolean`
Like `move(direction, true)`.

Example use:

```lua
local component = require("component")
local event = require("event")
local sides = require("sides")

local cc = component.carriage -- get primary carriage controller
cc.move("up")
local _, _, result, reason, x, y, z = event.pull("carriage_moved")
if not result then
  if x then
    print(reason)
    print("Block location: " .. x .. ", " .. y .. ", " .. z)
  else
    print(reason)
  end
end
-- using the sides table:
cc.simulate(sides.west)
```

## Contents
