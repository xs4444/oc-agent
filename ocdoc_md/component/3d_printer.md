# 3D Printer

This component is provided by the [3D Printer](../block/3d_printer.md) block.

Component name: `printer3d`.

Callbacks:

- `commit(count:number):boolean`
  Commit and begin printing the current configuration.
- `setLabel(value:string)`
  Set the label for the volume being printed.
- `getLabel():string`
  Get the current label for the volume being printed.
- `setTooltip(value:string)`
  Sets the tooltip for the volume being printed.
- `getTooltip():string`
  Gets the current tooltip of the volume being printed.
- `setButtonMode(value:boolean)`
  Set whether the printed block should automatically return to its off state.
- `isButtonMode():boolean`
  Gets whether the printed block should automatically return to its off state.
- `setRedstoneEmitter(value:boolean)`
  Sets whether the printed block should emit a redstone signal while in its active state.
- `isRedstoneEmitter():boolean`
  Gets whether the printed block should emit a redstone signal while in its active state.
- `addShape(minX:number, minY:number, minZ:number, maxX:number, maxY:number, maxZ:number, texture:string [,state:boolean = false] [,tint:number])`
  Adds the shape to the printer's current configuration, optionally specifying whether it is for the off or on state.
- `getShapeCount():number`
  Gets the number of shapes in the current configuration.
- `getMaxShapeCount():number`
  Gets the maximum allowed number of shapes.
- `status():string, number or boolean`
  The current state of the printer, 'busy' or 'idle' (string), followed by the progress (number) or model validity (boolean), respectively.
- `reset()`
  Resets the current job for the printer and stops printing (current job being printed will finish).

## Contents
