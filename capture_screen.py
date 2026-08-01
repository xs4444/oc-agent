#!/usr/bin/env python3
"""Screenshot capture utility for Minecraft/OpenComputers testing."""

import sys
from PIL import ImageGrab

def capture_screenshot(output_path="screenshot.png"):
    """Capture the full screen and save as PNG."""
    try:
        screenshot = ImageGrab.grab()
        screenshot.save(output_path, "PNG")
        print(f"Screenshot saved to: {output_path}")
        print(f"Resolution: {screenshot.size}")
        return True
    except Exception as e:
        print(f"Error capturing screenshot: {e}", file=sys.stderr)
        return False

if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "screenshot.png"
    success = capture_screenshot(output)
    sys.exit(0 if success else 1)
