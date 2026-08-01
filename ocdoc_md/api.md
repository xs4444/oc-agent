### APIs

## Standard Libraries

First and foremost you should get familiar with the [Lua reference manual](http://www.lua.org/manual/5.3/manual.html), if you are new to Lua. You will find most basic Lua functionality explained there, as well as a bunch of standard library functions.

OpenComputers makes an effort to largely emulate the standard library in areas that would usually interact with the host system - that being the I/O library. There are a few differences, which you can look up here: [differences in the standard libraries](api/non-standard-lua-libs.md). Most notably, the debug library is mostly unavailable, and `load` only accepts text source files, no binary / pre-compiled Lua programs (for security reasons).

These standard libraries are available in the global environment and thus are immediately available; meaning they do not need to be loaded in your scripts to be accessible.

  * [coroutine](api/non-standard-lua-libs.md#coroutine-manipulation)
  * [debug](api/non-standard-lua-libs.md#debug)
  * [io](api/non-standard-lua-libs.md#input-and-output-facilities)
  * [math](api/non-standard-lua-libs.md#mathematical-functions)
  * [os](api/non-standard-lua-libs.md#operating-system-facilities)
  * [package](api/non-standard-lua-libs.md#modules)
  * `print` Not a library, but a commonly used standard method for printing text to stdout.

```lua
print("hello world")
```

  * [string](api/non-standard-lua-libs.md#string-manipulation)
  * [table](api/non-standard-lua-libs.md#table-manipulation)

## Custom Libraries

Following is a description of the non-standard libraries, provided for convenience.

Note that you need to `require` all non-standard APIs before you use them, i.e. all modules not listed in the [Lua reference manual](http://www.lua.org/manual/5.3/manual.html) nor in [standard libraries](#standard-libraries). For example, instead of simple going `local rs = component.redstone`, you now need to require the component API, like so:

```lua
local component = require("component")
local rs = component.redstone

--You can of course change the variable name:
local mycomp = require("component")
local rs = mycomp.redstone
```
The same applies for all other APIs listed below (even `sides` and `colors`).

The standard libraries aside, OpenComputers comes with a couple of additional, built-in libraries. Here is a list of all these libraries. Note that some of these may not be usable depending on your configuration (HTTP) and context (Robot library on computers), but they'll still be there.

- [buffer](api/buffer.md): a Lua `FILE*` API buffer implementation for wrapping streams.
- [colors](api/colors.md): a global table that allows referencing standard Minecraft colors by name.
- [component](api/component.md): look-up and management of components attached to the computer.
- [computer](api/computer.md): information on and interactions with the computer the Lua state is running on.
- [event](api/event.md): an event system, often used by libraries, for pulling and registering handlers to signals.
- [uuid](api/uuid.md): creates long unique identifier strings in the common 8-4-4-4-12 format.
- [filesystem](api/filesystem.md): abstracted interaction with file system components.
- [internet](api/internet.md): a wrapper for Internet Card functionality.
- [keyboard](api/keyboard.md): a table of key codes by name and pressed key tracking.
- [note](api/note.md): converts music notes between their real name, their MIDI code and their frequency
- [process](api/process.md): keeps track of running programs and their environments.
- [rc](api/rc.md): provides automatic program execution and service management.
- [robot](api/robot.md): abstracted access to robot actions.
- [serialization](api/serialization.md): allows serialization of values, e.g. for sending them via the network.
- [shell](api/shell.md): working path tracking and program execution.
- [sides](api/sides.md): a global table that allows referencing sides by name.
- [term](api/term.md): provides the concept of the cursor, to read and write from keyboard input and screen output, respectively.
- [text](api/text.md): provides text utilities such as tab to space conversion.
- [thread](api/thread.md): provides autonomous and non-blocking cooperative threads.
- [transforms](api/transforms.md): provides helpful and advanced table manipulators.
- [unicode](api/unicode.md): provides Unicode aware implementations of some functions in the string library.

## Contents
