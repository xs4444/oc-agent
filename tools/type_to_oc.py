#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Paste text into Minecraft OC terminal via middle-click."""

import sys
import time
import ctypes
from ctypes import wintypes

CF_UNICODETEXT = 13

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]

class INPUT(ctypes.Structure):
    _fields_ = [
        ("type", wintypes.DWORD),
        ("mi", MOUSEINPUT),
    ]

INPUT_MOUSE = 0
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040

WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def find_minecraft_window():
    user32 = ctypes.windll.user32
    found = None
    def cb(hwnd, _):
        nonlocal found
        if not user32.IsWindowVisible(hwnd): return True
        buf = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(hwnd, buf, 256)
        t = buf.value
        for kw in ['minecraft', 'Minecraft', 'GTNH', 'GT: New Horizons', 'GT New Horizons']:
            if kw in t:
                found = hwnd
                return False
        return True
    user32.EnumWindows(WNDENUMPROC(cb), 0)
    return found

def get_window_rect(hwnd):
    user32 = ctypes.windll.user32
    rect = ctypes.wintypes.RECT()
    try:
        dwmapi = ctypes.windll.dwmapi
        if dwmapi.DwmGetWindowAttribute(hwnd, 9, ctypes.byref(rect), ctypes.sizeof(rect)) == 0:
            return (rect.left, rect.top, rect.right, rect.bottom)
    except: pass
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return (rect.left, rect.top, rect.right, rect.bottom)

def set_clipboard(text):
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    
    # Set correct argtypes for 64-bit handles
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = wintypes.HANDLE
    kernel32.GlobalLock.argtypes = [wintypes.HANDLE]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [wintypes.HANDLE]
    kernel32.GlobalUnlock.restype = wintypes.BOOL
    kernel32.GlobalFree.argtypes = [wintypes.HANDLE]
    kernel32.GlobalFree.restype = wintypes.HANDLE
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.OpenClipboard.restype = wintypes.BOOL
    user32.EmptyClipboard.argtypes = []
    user32.EmptyClipboard.restype = wintypes.BOOL
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user32.SetClipboardData.restype = wintypes.HANDLE
    user32.CloseClipboard.argtypes = []
    user32.CloseClipboard.restype = wintypes.BOOL
    
    if not user32.OpenClipboard(None):
        return False
    hMem = None
    try:
        user32.EmptyClipboard()
        size = (len(text) + 1) * 2
        hMem = kernel32.GlobalAlloc(0x0042, size)
        if not hMem: return False
        ptr = kernel32.GlobalLock(hMem)
        if not ptr:
            kernel32.GlobalFree(hMem)
            return False
        try:
            data = text.encode('utf-16-le')
            ctypes.memmove(ptr, data, len(data))
        finally:
            kernel32.GlobalUnlock(hMem)
        if not user32.SetClipboardData(CF_UNICODETEXT, hMem):
            kernel32.GlobalFree(hMem)
            return False
        hMem = None
        return True
    finally:
        user32.CloseClipboard()

def middle_click(x, y):
    user32 = ctypes.windll.user32
    sw = user32.GetSystemMetrics(0)
    sh = user32.GetSystemMetrics(1)
    ax = int((x * 65535) / (sw - 1))
    ay = int((y * 65535) / (sh - 1))
    inputs = []
    for flags in [
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE,
        MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MIDDLEDOWN,
        MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MIDDLEUP
    ]:
        inp = INPUT()
        inp.type = INPUT_MOUSE
        inp.mi.dx = ax
        inp.mi.dy = ay
        inp.mi.dwFlags = flags
        inputs.append(inp)
    arr = (INPUT * len(inputs))(*inputs)
    return user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT)) == len(inputs)

def main():
    if len(sys.argv) < 2:
        print("Usage: python type_to_oc.py <text>")
        print("       python type_to_oc.py -f <file>")
        print("       echo text | python type_to_oc.py -")
        return 1
    if sys.argv[1] == '-':
        text = sys.stdin.read()
    elif sys.argv[1] == '-f' and len(sys.argv) > 2:
        with open(sys.argv[2], 'r', encoding='utf-8') as f:
            text = f.read()
    else:
        text = sys.argv[1]
    text = text.replace('\r\n', '\n').rstrip('\n')
    if not text:
        print("No text", file=sys.stderr)
        return 1
    hwnd = find_minecraft_window()
    if not hwnd:
        print("No MC window", file=sys.stderr)
        return 1
    l, t, r, b = get_window_rect(hwnd)
    cx = l + (r - l) // 2
    cy = t + int((b - t) * 0.55)
    if not set_clipboard(text):
        print("Clipboard failed", file=sys.stderr)
        return 1
    time.sleep(0.2)
    if middle_click(cx, cy):
        print("OK")
        return 0
    else:
        print("Click failed", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
