#!/usr/bin/env bash
# The installation itself, for nixith-installer (./installer.c): partitions
# and formats the disk (or takes what is mounted on /mnt), writes
# /etc/nixith/configuration.nix the way the Calamares installer did
# (../calamares-nixithos/patch-main.py) and runs `nixith install`.
#
# Everything comes in the environment (NI_*, see the list below). The
# installer reads the standard output: "::step N TEXT" starts a step,
# "::done" ends it all, "::fail TEXT" says what went wrong; every other line
# is the log.
#
#   NI_DRY=1 install.sh    the plan and configuration.nix, nothing done
set -euo pipefail

: "${NI_MODE:=erase}"        # erase | manual (the user mounted /mnt)
: "${NI_DISK:=}"             # /dev/sdX: erased, or the BIOS boot disk
: "${NI_FS:=ext4}"           # ext4 | btrfs
: "${NI_FIRMWARE:=efi}"      # efi | bios
: "${NI_TZ:=UTC}"
: "${NI_LOCALE:=en_US.UTF-8}"
: "${NI_KB_LAYOUT:=us}"      # xkb, e.g. "us,ru"
: "${NI_KB_OPTIONS:=}"       # xkb, e.g. "grp:alt_shift_toggle"
: "${NI_CONSOLE_KEYMAP:=us}"
: "${NI_CYRILLIC:=0}"        # a console font with Cyrillic
: "${NI_FULLNAME:=}"
: "${NI_USER:=user}"
: "${NI_USER_HASH:=!}"       # crypt(3) hashes, made by the installer
: "${NI_ROOT_HASH:=!}"
: "${NI_HOST:=nixith}"
: "${NI_AUTOLOGIN:=0}"
: "${NI_DESKTOP:=none}"      # dwl parallax gnome plasma hyprland niri | none
: "${NI_DM:=ly}"             # ly | greetd | none
: "${NI_SHELL:=bash}"        # bash zsh fish nushell
: "${NI_LOADER:=systemd-boot}"  # systemd-boot limine grub refind (UEFI)
: "${NI_UNFREE:=0}"
: "${NI_DRY:=0}"
root=/mnt

step() { echo "::step $1 $2"; }
fail() {
    echo "::fail $*"
    exit 1
}
run() {
    echo "\$ $*"
    if [ "$NI_DRY" != 1 ]; then "$@"; fi
}

# a Nix string
nix() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$\{/\\\$\{}
    printf '"%s"' "$s"
}

# the n-th partition of a disk: sda1, nvme0n1p1, mmcblk0p1
part() {
    case $1 in
        *[0-9]) echo "$1p$2" ;;
        *) echo "$1$2" ;;
    esac
}

config() {
    cat << EOF
# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (\`nixos-help\`;
# NixithOS is NixOS without systemd).  Apply changes with
# \`sudo nixith switch\`.

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

EOF
    if [ "$NI_FIRMWARE" = bios ]; then
        cat << EOF
  # The boot loader: GRUB.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = $(nix "$NI_DISK");
  boot.loader.grub.useOSProber = true;

EOF
    else
        case $NI_LOADER in
            limine)
                cat << 'EOF'
  # The boot loader: Limine.
  boot.loader.limine.enable = true;
  boot.loader.limine.efiSupport = true;
  boot.loader.efi.canTouchEfiVariables = true;

EOF
                ;;
            grub)
                cat << 'EOF'
  # The boot loader: GRUB.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.useOSProber = true;
  boot.loader.efi.canTouchEfiVariables = true;

EOF
                ;;
            refind)
                cat << 'EOF'
  # The boot loader: rEFInd.
  boot.loader.refind.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # (unlike the others, rEFInd's module leaves GRUB on)
  boot.loader.grub.enable = false;

EOF
                ;;
            *)
                cat << 'EOF'
  # The boot loader: systemd-boot.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

EOF
                ;;
        esac
    fi
    cat << EOF
  networking.hostName = $(nix "$NI_HOST");

  # Enable networking (\`nmtui\` or \`nixith-net\` to connect).
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = $(nix "$NI_TZ");

  # Select internationalisation properties.
  i18n.defaultLocale = $(nix "$NI_LOCALE");

  # Configure the keyboard layout.
  services.xserver.xkb = {
    layout = $(nix "$NI_KB_LAYOUT");
    variant = "";
    options = $(nix "$NI_KB_OPTIONS");
  };
  console.keyMap = $(nix "$NI_CONSOLE_KEYMAP");

EOF
    if [ "$NI_CYRILLIC" = 1 ]; then
        cat << 'EOF'
  # A console font with Cyrillic (set from the start, in the initrd).
  console.font = "ter-v16n";
  console.packages = [ pkgs.terminus_font ];
  console.earlySetup = true;

EOF
    fi
    # swap in compressed memory: no partition or file to size
    cat << 'EOF'
  # Swap in compressed memory.
  zramSwap.enable = true;

EOF
    if [ "$NI_DESKTOP" != none ]; then
        local dmname
        case $NI_DM in
            greetd) dmname="greetd (tuigreet)" ;;
            none) dmname="the console (no display manager)" ;;
            *) dmname=$NI_DM ;;
        esac
        cat << EOF
  # The desktop of NixithOS: $NI_DESKTOP, logged into through $dmname.
  nixithos.desktop.$NI_DESKTOP.enable = true;
  nixithos.desktop.displayManager = "$NI_DM";
  nixithos.utilities.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Install firefox.
  programs.firefox.enable = true;

EOF
    fi
    cat << EOF
  # Define a user account.
  users.users.$(nix "$NI_USER") = {
    isNormalUser = true;
    description = $(nix "$NI_FULLNAME");
    extraGroups = [ "networkmanager" "wheel" "video" "audio" ];
    # (the password given in the installer; \`passwd\` changes it)
    initialHashedPassword = $(nix "$NI_USER_HASH");
  };
  users.users.root.initialHashedPassword = $(nix "$NI_ROOT_HASH");

EOF
    case $NI_SHELL in
        zsh)
            cat << EOF
  # The users' shell: zsh (without the questions of its zsh-newuser-install
  # on the first start, before there is a ~/.zshrc).
  programs.zsh.enable = true;
  programs.zsh.shellInit = "zsh-newuser-install() { unfunction zsh-newuser-install; }";
  users.users.$(nix "$NI_USER").shell = pkgs.zsh;

EOF
            ;;
        fish)
            cat << EOF
  # The users' shell: fish.
  programs.fish.enable = true;
  users.users.$(nix "$NI_USER").shell = pkgs.fish;

EOF
            ;;
        nushell)
            cat << EOF
  # The users' shell: nushell.
  environment.shells = [ pkgs.nushell ];
  users.users.$(nix "$NI_USER").shell = pkgs.nushell;

EOF
            ;;
    esac
    if [ "$NI_AUTOLOGIN" = 1 ]; then
        if [ "$NI_DESKTOP" != none ] && [ "$NI_DM" != none ]; then
            cat << EOF
  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = $(nix "$NI_USER");

EOF
        else
            cat << EOF
  # Enable automatic login for the user.
  services.getty.autologinUser = $(nix "$NI_USER");

EOF
        fi
    fi
    if [ "$NI_UNFREE" = 1 ]; then
        cat << 'EOF'
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

EOF
    fi
    cat << EOF
  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  # environment.systemPackages = with pkgs; [
  #   vim
  #   wget
  # ];

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # This option defines the first version of NixOS you have installed on this
  # particular machine, and is used to keep compatibility with application
  # data (e.g. databases) created on older versions.  Do not change it.
  system.stateVersion = "$(version)";
}
EOF
}

version() {
    local v
    v=$(nixith version 2> /dev/null || echo 26.05)
    echo "${v:0:5}"
}

if [ "$NI_DRY" = 1 ]; then
    echo "== the plan"
fi

# --- 1. the disk -------------------------------------------------------------

step 1 "Preparing the disk"
if [ "$NI_MODE" = erase ]; then
    [ -b "$NI_DISK" ] || [ "$NI_DRY" = 1 ] || fail "$NI_DISK is not a disk"
    if [ "$NI_DRY" != 1 ]; then
        # nothing of the disk may stay mounted or in use
        umount -R "$root" 2> /dev/null || true
        for p in $(lsblk -lnpo NAME "$NI_DISK" | tail -n +2); do
            umount "$p" 2> /dev/null || true
            swapoff "$p" 2> /dev/null || true
        done
    fi
    run wipefs -af "$NI_DISK"
    if [ "$NI_FIRMWARE" = efi ]; then
        echo "\$ sfdisk $NI_DISK: GPT, 1 GiB EFI system partition, the rest for the system"
        [ "$NI_DRY" = 1 ] || printf 'label: gpt\nsize=1GiB, type=uefi, name=boot\ntype=linux, name=nixith\n' |
            sfdisk --wipe always --wipe-partitions always "$NI_DISK"
    else
        echo "\$ sfdisk $NI_DISK: GPT, 1 MiB BIOS boot partition for GRUB, the rest for the system"
        [ "$NI_DRY" = 1 ] || printf 'label: gpt\nsize=1MiB, type=21686148-6449-6E6F-744E-656564454649, name=bios\ntype=linux, name=nixith\n' |
            sfdisk --wipe always --wipe-partitions always "$NI_DISK"
    fi
    run partprobe "$NI_DISK" || true
    run udevadm settle
    boot=$(part "$NI_DISK" 1)
    system=$(part "$NI_DISK" 2)

    step 2 "Creating file systems"
    if [ "$NI_FIRMWARE" = efi ]; then
        run mkfs.fat -F 32 -n BOOT "$boot"
    fi
    if [ "$NI_FS" = btrfs ]; then
        run mkfs.btrfs -f -L nixith "$system"
    else
        run mkfs.ext4 -F -L nixith "$system"
    fi
    run udevadm settle
    run mount "$system" "$root"
    if [ "$NI_FIRMWARE" = efi ]; then
        run mkdir -p "$root/boot"
        run mount -o umask=0077 "$boot" "$root/boot"
    fi
else
    step 2 "Checking /mnt"
    [ "$NI_DRY" = 1 ] || mountpoint -q "$root" || fail "nothing is mounted on $root"
    if [ "$NI_FIRMWARE" = efi ] && [ "$NI_DRY" != 1 ]; then
        mountpoint -q "$root/boot" || fail "the EFI system partition is not mounted on $root/boot"
    fi
fi

# --- 2. the configuration ----------------------------------------------------

step 3 "Writing the configuration"
run nixith generate-config --root "$root"
if [ "$NI_DRY" = 1 ]; then
    echo "== $root/etc/nixith/configuration.nix"
    config
else
    config > "$root/etc/nixith/configuration.nix"
    sed 's/^/  /' "$root/etc/nixith/configuration.nix" | grep -v 'HashedPassword'
fi

# --- 3. the installation -----------------------------------------------------

step 4 "Installing NixithOS"
# (Nix wants its build directory without world-writable parents.)  A
# download can break off (a TLS reset from the binary cache, a flaky Wi-Fi):
# then what failed is built from source instead (fallback), and the whole
# command is tried again, keeping what it already has in /mnt.
for attempt in 1 2 3; do
    if run nixith install --root "$root" --no-root-passwd \
        --option build-dir /nix/var/nix/builds \
        --option fallback true \
        --option download-attempts 10 \
        --option connect-timeout 20; then
        break
    fi
    [ "$attempt" = 3 ] && fail "nixith install failed three times"
    echo "== nixith install failed; trying again ($((attempt + 1)) of 3)"
    sleep 5
done

step 5 "Finishing"
run sync
echo "::done"
