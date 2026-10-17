# Makes the `nixos` module of calamares-nixos-extensions (main.py, which
# writes configuration.nix and runs the installation) NixithOS's:
#
#   - the desktops: NixithOS's own (nixithos.desktop.<id>), in place of
#     NixOS's with GDM or SDDM, and what to log in through (ly, greetd or
#     the console: nixithos.desktop.displayManager);
#   - the users' shell (bash, zsh, fish or nushell);
#   - the boot loader (systemd-boot, Limine, GRUB or rEFInd on UEFI; GRUB on
#     BIOS);
#   - the configuration in /etc/nixith, written by `nixith generate-config`
#     and installed by `nixith install`;
#   - the name: NixithOS, and "nixith" for a machine nobody named.
#
#   python3 patch-main.py main.py
import ast
import sys

path = sys.argv[1]
s = open(path).read()


def replace(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"patch-main.py: {old!r} is there {n} times, not {count}")
    s = s.replace(old, new)


# the desktops, display managers, shells and boot loaders (ids of
# packagechooser*.conf)
replace(
    'cfgbootefi = """',
    '''NIXITHOS_DESKTOPS = ("dwl", "parallax", "gnome", "plasma", "hyprland", "niri")

cfgnixithos = """\\
  # The desktop of NixithOS: @@desktop@@, logged into through @@dmname@@.
  nixithos.desktop.@@desktop@@.enable = true;
  nixithos.desktop.displayManager = "@@dm@@";
  nixithos.utilities.enable = true;

"""

NIXITHOS_DM_NAMES = {
    "ly": "ly",
    "greetd": "greetd (tuigreet)",
    "none": "the console (no display manager)",
}

NIXITHOS_SHELLS = {
    "zsh": """\\
  # The users' shell: zsh (without the questions of its zsh-newuser-install
  # on the first start, before there is a ~/.zshrc).
  programs.zsh.enable = true;
  programs.zsh.shellInit = "zsh-newuser-install() { unfunction zsh-newuser-install; }";
  users.users."@@username@@".shell = pkgs.zsh;

""",
    "fish": """\\
  # The users' shell: fish.
  programs.fish.enable = true;
  users.users."@@username@@".shell = pkgs.fish;

""",
    "nushell": """\\
  # The users' shell: nushell.
  environment.shells = [ pkgs.nushell ];
  users.users."@@username@@".shell = pkgs.nushell;

""",
}

NIXITHOS_EFI_LOADERS = {
    "systemd-boot": """\\
  # The boot loader: systemd-boot.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

""",
    "limine": """\\
  # The boot loader: Limine.
  boot.loader.limine.enable = true;
  boot.loader.limine.efiSupport = true;
  boot.loader.efi.canTouchEfiVariables = true;

""",
    "grub": """\\
  # The boot loader: GRUB.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.useOSProber = true;
  boot.loader.efi.canTouchEfiVariables = true;

""",
    "refind": """\\
  # The boot loader: rEFInd.
  boot.loader.refind.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # (unlike the others, rEFInd's module leaves GRUB on)
  boot.loader.grub.enable = false;

""",
}

cfgbootgrubbtrfs = """\\
  # Use provided UUIDs instead of blkid probing (required for btrfs subvolumes)
  boot.loader.grub.fsIdentifier = "provided";

"""

cfgbootefi = """''',
)

# the boot loader of one's choice on UEFI (on BIOS only GRUB: systemd-boot,
# rEFInd and Limine on a disk with no FAT /boot need UEFI)
replace(
    '''    if fw_type == "efi":
        cfg += cfgbootefi
''',
    '''    loader = gs.value("packagechooser_bootloader") or "systemd-boot"
    if fw_type == "efi" and loader in NIXITHOS_EFI_LOADERS:
        cfg += NIXITHOS_EFI_LOADERS[loader]
        if loader == "grub" and root_is_btrfs:
            cfg += cfgbootgrubbtrfs
    elif fw_type == "efi":
        cfg += cfgbootefi
''',
)
replace(
    '''    # Choose desktop environment
    if gs.value("packagechooser_packagechooser") == "gnome":''',
    '''    # Choose desktop environment
    if gs.value("packagechooser_packagechooser") in NIXITHOS_DESKTOPS:
        cfg += cfgnixithos
        catenate(variables, "desktop", gs.value("packagechooser_packagechooser"))
        dm = gs.value("packagechooser_displaymanager") or "ly"
        catenate(variables, "dm", dm)
        catenate(variables, "dmname", NIXITHOS_DM_NAMES.get(dm, dm))
    elif gs.value("packagechooser_packagechooser") == "gnome":''',
)
# without a display manager the automatic login is the console's (and dwl
# starts by itself on tty1); the shell of one's choice for the user
replace(
    '''            and gs.value("packagechooser_packagechooser") != ""
        ):
            cfg += cfgautologin''',
    '''            and gs.value("packagechooser_packagechooser") != ""
            and (gs.value("packagechooser_displaymanager") or "ly") != "none"
        ):
            cfg += cfgautologin''',
)
replace(
    '''        cfg += cfgusers
''',
    '''        cfg += cfgusers
        cfg += NIXITHOS_SHELLS.get(gs.value("packagechooser_shell") or "bash", "")
''',
)

# /etc/nixith, and nixith's tools
replace('"etc/nixos/configuration.nix"', '"etc/nixith/configuration.nix"')
replace('"/etc/nixos/hardware-configuration.nix"', '"/etc/nixith/hardware-configuration.nix"', 2)
replace('["pkexec", "nixos-generate-config", "--root", root_mount_point]', '["pkexec", "nixith-generate-config", "--root", root_mount_point]')
replace('_("nixos-generate-config failed")', '_("nixith generate-config failed")')
replace('''            "nixos-install",
            "--no-root-passwd",''', '''            "nixith-install",
            "--no-root-passwd",''')
replace('_("nixos-install failed")', '_("nixith install failed")', 2)
replace('subprocess.getoutput(["nixos-version"])', 'subprocess.getoutput(["nixith-version"])')
replace('catenate(variables, "hostname", "nixos")', 'catenate(variables, "hostname", "nixith")')

# the name, wherever it is said
s = s.replace("NixOS manual (`nixos-help`)", "@MANUAL@")
s = s.replace("NixOS", "NixithOS")
s = s.replace("@MANUAL@", "NixOS manual (`nixos-help`; NixithOS is NixOS without systemd)")

ast.parse(s)
open(path, "w").write(s)
