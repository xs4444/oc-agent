#!/usr/bin/env python3
"""Screenshot capture utility - brings Minecraft to foreground before capturing."""

import sys
import time
import ctypes
from ctypes import wintypes
from PIL import ImageGrab

# Windows API constants
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
SW_RESTORE = 9
SW_SHOW = 5
SW_MINIMIZE = 6
GWL_STYLE = -16
WS_MINIMIZE = 0x20000000

class RECT(ctypes.Structure):
    _fields_ = [
        ("left", wintypes.LONG),
        ("top", wintypes.LONG),
        ("right", wintypes.LONG),
        ("bottom", wintypes.LONG)
    ]

def find_minecraft_window():
    """Find Minecraft window handle."""
    user32 = ctypes.windll.user32
    
    found_hwnd = None
    
    def callback(hwnd, extra):
        nonlocal found_hwnd
        if not user32.IsWindowVisible(hwnd):
            return True
        
        title = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(hwnd, title, 256)
        window_title = title.value
        
        minecraft_keywords = ['minecraft', 'Minecraft', 'GTNH', 'GT: New Horizons', 
                              'GT New Horizons', '梦大师', 'gtnh']
        
        for keyword in minecraft_keywords:
            if keyword in window_title:
                found_hwnd = hwnd
                print(f"Found window: '{window_title}' (hwnd={hwnd})")
                return False
        
        return True
    
    cb = WNDENUMPROC(callback)
    user32.EnumWindows(cb, 0)
    
    return found_hwnd

def is_minimized(hwnd):
    """Check if window is minimized."""
    user32 = ctypes.windll.user32
    style = user32.GetWindowLongW(hwnd, GWL_STYLE)
    return bool(style & WS_MINIMIZE)

def bring_to_foreground(hwnd):
    """Bring window to foreground if minimized. Minimal window manipulation."""
    user32 = ctypes.windll.user32
    
    # Only restore if minimized - never use SetWindowPos or SetForegroundWindow
    # to avoid triggering Windows 'show desktop' behavior
    if is_minimized(hwnd):
        print("Window is minimized, restoring...")
        user32.ShowWindow(hwnd, SW_RESTORE)
        time.sleep(0.5)
    
    return True

def get_window_rect(hwnd):
    """Get window position and size."""
    user32 = ctypes.windll.user32
    rect = RECT()
    
    # Use DWM for accurate bounds
    try:
        dwmapi = ctypes.windll.dwmapi
        result = dwmapi.DwmGetWindowAttribute(
            hwnd, 9, ctypes.byref(rect), ctypes.sizeof(rect)
        )
        if result == 0:
            return (rect.left, rect.top, rect.right, rect.bottom)
    except:
        pass
    
    # Fallback
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return (rect.left, rect.top, rect.right, rect.bottom)

def capture_window(hwnd, output_path="minecraft_screenshot.png", bring_front=True):
    """Capture specific window, optionally bringing it to foreground first."""
    try:
        if bring_front:
            bring_to_foreground(hwnd)
        
        left, top, right, bottom = get_window_rect(hwnd)
        width = right - left
        height = bottom - top
        
        print(f"Window bounds: ({left}, {top}) -> ({right}, {bottom}), size: {width}x{height}")
        
        if width <= 0 or height <= 0:
            print("Invalid window size", file=sys.stderr)
            return False
        
        # Final wait to ensure it's rendered
        time.sleep(0.2)
        
        screenshot = ImageGrab.grab(bbox=(left, top, right, bottom))
        screenshot.save(output_path, "PNG")
        
        print(f"Screenshot saved: {output_path} ({width}x{height})")
        return True
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return False

def main():
    print("Searching for Minecraft window...")
    hwnd = find_minecraft_window()
    
    if hwnd is None:
        print("Minecraft window not found! Is the game running?", file=sys.stderr)
        print("\nRunning windows:")
        user32 = ctypes.windll.user32
        def list_callback(hwnd, extra):
            if user32.IsWindowVisible(hwnd):
                title = ctypes.create_unicode_buffer(256)
                user32.GetWindowTextW(hwnd, title, 256)
                if title.value.strip():
                    print(f"  - {title.value}")
            return True
        cb = WNDENUMPROC(list_callback)
        user32.EnumWindows(cb, 0)
        return 1
    
    # Check if we should bring to front (default yes)
    bring_front = True
    if len(sys.argv) > 1 and sys.argv[1] == "--no-focus":
        bring_front = False
        sys.argv.pop(1)
    
    output = sys.argv[1] if len(sys.argv) > 1 else "minecraft_screenshot.png"
    success = capture_window(hwnd, output, bring_front)
    
    return 0 if success else 1

if __name__ == "__main__":
    sys.exit(main())
