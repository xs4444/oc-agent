# Loot Disks

OpenComputers provides floppy disks that can be crafted (but not found as loot, such as in dungeon chests). Most notably, the [OpenOS floppy disk](openos_floppy.md) is a loot disk from which one can [install OpenOS](../openos.md).

Originally these disks were found as loot, such as in dungeon chests. But for many versions the only way to obtain these floppy disks has been to craft them. You can craft any loot disk by placing a [scrench](scrench.md) and any loot disk in a crafting table and cycle to the next. Repeat the process to craft the next loot disk. The order is unspecified.

Showcased here is the OpenOS loot disk. The other loot disks look similar; they have different coloring and have their loot disk name printed on the disk image.

![](../media/recipes/items/openos.png)

## Loot Disk List

When floppy disks are inserted into computers their filesystems are automounted and the user can browse the files at will.

However, it is anticipated that a user will want to run the programs provided by loot disks as a natural part of their systems, i.e. they will want to [install](../openos.md#install-tool) them. Thus in the explanation of these loot disks, it is omitted and assumed the user runs `install` after inserting a disk into their computer.

* builder

  A robot program for automated building following a **plan** file.

* data

  A software package for [data cards](data_card.md). It contains a set of helpful and advanced data manipulating tools, including `md5sum`,  `deflate` and `inflate` for compression, and `gpg`.

* dig

  A robot program for digging holes.

* generator

  A robot program for keeping it powered.

* internet

  A software package for [internet cards](internet_card.md). It includes `wget`, and `pastebin`.

* irc

  A minimalistic irc client.

* maze

  A robot program to build random mazes.

* network

  A software package for [network cards](network_card.md). It includes various in-game LAN tools, including `ping`.

* openloader

  A simple bootloader that gives power to choose which system to boot.

* openos

  [Craftable](openos_floppy.md) item. It provides a bootable medium and comes with an installer you can invoke by running `install`. This is OpenComputer's standard operating system, which is to say that when you are reading the documentation, conversing in the forums or irc channel, or posting issues on github (unless otherwise stated) it is assumed the user is running OpenOS. [Here](../openos.md) is a more detailed explanation of its install process.

* oppm

  Crafted using a [plain floppy](floppy_disk.md) and an [interweb](materials.md#interweb). [Here](../tutorial/program_oppm.md) is a more detailed explanation of its usage.

* plan9k

  An alternative operating system by Magik6k.

## Contents
