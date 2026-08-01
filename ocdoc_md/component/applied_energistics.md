# Components: Applied Energistics
This page covers AE2 components made available with the [adapter](../block/adapter.md).

Mod integration is a moving target. This document refers to AE2 rv6 and OC 1.7.3 (or 1.7.2 dev builds) for minecraft 1.12.

## Common Network API

All AE2 components provide a common network api

## ME Controller

AE2 [ME Controller](https://ae-mod.info/ME-Controller/) -> `me_controller`

The `me_controller` provides the [Common Network API](#common-network-api) and the following:

### Craftable

`userdata` objects returned from any ae2 network component `getCraftables`

### Crafting Status

`userdata` objects returned from calling `request` on [Craftable](#craftable)

## ME Interface

AE2 [ME Interface](https://ae-mod.info/ME-Interface/) -> `me_interface`

The `me_interface` provides the [Common Network API](#common-network-api) and the following:

## ME Import Bus

AE2 [ME Import Bus](https://ae-mod.info/ME-Import-Bus/) -> `me_importbus`

The `me_importbus` provides the [Common Network API](#common-network-api) and the following:

## ME Export Bus

AE2 [ME Export Bus](https://ae-mod.info/ME-Export-Bus/) -> `me_exportbus`

The `me_exportbus` provides the [Common Network API](#common-network-api) and the following:

---
