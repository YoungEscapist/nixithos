# Adds the steps after the desktop to Calamares's settings.conf: what to log
# in through, the shell, the boot loader (packagechooser@<id>, each with
# packagechooser-<id>.conf).
#
#   python3 patch-settings.py settings.conf
import sys

STEPS = ("displaymanager", "shell", "bootloader")

path = sys.argv[1]
s = open(path).read()


def replace(old, new):
    global s
    if s.count(old) != 1:
        sys.exit(f"patch-settings.py: {old!r} is there {s.count(old)} times, not once")
    s = s.replace(old, new)


replace(
    "\ninstances:\n",
    "\ninstances:\n"
    + "".join(
        f"- id:       {i}\n  module:   packagechooser\n  config:   packagechooser-{i}.conf\n"
        for i in STEPS
    ),
)
replace(
    "  - packagechooser\n",
    "  - packagechooser\n" + "".join(f"  - packagechooser@{i}\n" for i in STEPS),
)
open(path, "w").write(s)
