# Helpers of the boot assessment tests (rollback-*.nix); `init` is the init
# system of the machine.

def assess(*args):
    return machine.succeed("nixith-boot-assess " + " ".join(args) + " 2>&1")


def booted():
    return machine.succeed("readlink -f /run/booted-system").strip()


def profile():
    return machine.succeed("readlink /nix/var/nix/profiles/system").strip()


def new_generation(spec):
    """What `nixith boot` does after the build: the system of a specialisation
    of the booted one becomes a new generation, and the boot loader is
    installed for it."""
    top = machine.succeed(f"readlink -f /run/booted-system/specialisation/{spec}").strip()
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {top}")
    out = machine.succeed(f"{top}/bin/switch-to-configuration boot 2>&1")
    print(out)
    return top, out


def boot_ended():
    """The end of the boot has been dealt with (the unit or hook that called
    nixith-boot-assess has done its work); returns what it came to."""
    machine.wait_until_succeeds("test -e /run/nixith/boot-assessed", timeout=1800)
    return machine.succeed("cat /run/nixith/boot-assessed").strip()


def reboot():
    machine.reboot()
    return boot_ended()
