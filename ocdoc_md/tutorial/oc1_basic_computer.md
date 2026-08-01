# OC Tutorial: Basic Computer
In this tutorial you will learn how to build a basic (Tier 1) computer.
This tutorial is using the default config file.

You will need:
  - [Tier 1 Case](../block/case.md)
  - [Tier 1 Screen](../block/screen.md)
  - [Keyboard](../block/keyboard.md)
  - [Tier 1 Graphics Card](../item/graphics_card.md)
  - [Tier 1 CPU](../item/cpu.md)
  - [Two Tier 1 RAM or 1 Tier 1.5 RAM](../item/memory.md)
  - [Disk Drive](../block/disk_drive.md)
  - [OpenOS Floppy Disk](../item/openos_floppy.md)
  - [Hard Disk Drive](../item/hard_disk_drive.md)
  - [Lua BIOS](../item/eeprom.md)
  - Source of Power

**Important:** Versions prior to 1.2.2 require a [Power Converter](../block/power_converter.md)

# Setting up your environment
The basic computer setup consists of a [Computer Case](../block/case.md) with a [Screen](../block/screen.md) on top and a [Keyboard](../block/keyboard.md) attached.

Here is an example with  the power source on the left and a basic setup on the right
![](http://i.imgur.com/TDIiBJr.png)

Now, you will need to right click on the computer case and put the items in here as shown
![](http://i.imgur.com/OrMN600.png)

Now, if you try to start the computer by clicking on the power button, you will end up getting an error:

![](http://i.imgur.com/jiGZKSR.png)
This means that there is no OS for the computer to run! To fix that, we will need to put a [Disk Drive](../block/disk_drive.md) directly next to the computer and place the [OpenOS Floppy Disk](../item/openos_floppy.md) in it.

Now, it should turn on.
![](http://i.imgur.com/SeEd9Xb.png)

Congratulations! You now have a fully working computer, but if you want more features, you will need to install OpenOS!

To install OpenOS, you will need to run the "install" command on the computer, which will allow you run the computer with out the OS Floppy.

**Next up: [Writing Programs](oc2_writing_code.md).**

## Contents
