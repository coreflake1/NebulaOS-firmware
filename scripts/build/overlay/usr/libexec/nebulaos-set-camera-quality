#!/usr/bin/env python3

# OpenKE - apply an end-user-selected camera quality preset (LOW/MED/HIGH)
# and restart the camera pipeline to pick it up.
#
# Camera quality presets mission (2026-08-04): writes the marker file
# S50webcam reads (see that script's own header comment for why LOW/MED
# leave fps uncapped rather than requesting a specific rate) and restarts
# it the same way reload_camera.py does - S50webcam already owns
# discovering the real UVC node and managing ustreamer's lifecycle, a
# plain restart is the correct, complete way to apply a new preset.

import subprocess
import sys

MARKER = "/usr/data/nebulaos/maintenance/camera-quality-mode"
S50WEBCAM = "/etc/init.d/S50webcam"
VALID = ("LOW", "MED", "HIGH")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in VALID:
        print(f"Usage: {sys.argv[0]} {{{'|'.join(VALID)}}}", file=sys.stderr)
        return 1

    quality = sys.argv[1]

    subprocess.run(["mkdir", "-p", "/usr/data/nebulaos/maintenance"], check=True)
    with open(MARKER, "w") as f:
        f.write(quality + "\n")

    subprocess.run([S50WEBCAM, "restart"], check=True)
    print(f"Camera quality set to {quality}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
