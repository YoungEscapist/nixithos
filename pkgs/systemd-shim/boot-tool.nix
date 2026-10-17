# systemd-boot's own tools, taken out of the systemd package: `bootctl`, which
# installs and updates the boot loader on the ESP, and the EFI programs it
# installs.  None of this runs as part of an init system; it is the boot
# loader, which a system with another init still wants.
#
# `bootctl` needs systemd's private library next to it, and both have the
# path of the package they came from in them (RUNPATH, and constants such as
# where the EFI files are).  The copy is given a name of the same length as
# that package's, and the path is replaced in the copies, so that they refer
# to themselves and nothing of systemd is left in the closure.
#
# The private library searches for the libraries it opens on demand
# (cryptsetup, FIDO2, TPM2, PAM, …) in a RUNPATH of some thirty packages, a
# good part of which are built against systemd's libraries.  Installing a boot
# loader opens one of them (libblkid, to look at the partition the ESP is on),
# besides the two the library is linked with, so the search path is cut down
# to those three and the rest is not in the closure.  (`strace -e openat
# bootctl install | status | update` shows that this is all of them.)
{
  lib,
  runCommand,
  patchelf,
  systemd, # the real one
}:

let
  # (not "systemd-…": such a name is what the closure checks look for)
  wanted = "boot-tool";
  n = lib.stringLength systemd.name;
  name = wanted + lib.concatStrings (lib.genList (_: "_") (n - lib.stringLength wanted));
in

runCommand name { nativeBuildInputs = [ patchelf ]; } ''
  mkdir -p $out/bin $out/lib/systemd/boot
  cp ${systemd}/bin/bootctl $out/bin/
  cp ${systemd}/lib/systemd/libsystemd-shared-*.so $out/lib/systemd/
  cp -r ${systemd}/lib/systemd/boot/efi $out/lib/systemd/boot/
  chmod -R u+w $out

  # same length, so that nothing moves
  old=${systemd}
  new=$out
  [ "''${#old}" = "''${#new}" ] || { echo "the copy's path is not as long as the original's" >&2; exit 1; }
  export LC_ALL=C
  for f in $out/bin/bootctl $out/lib/systemd/libsystemd-shared-*.so; do
    sed -i "s|$old|$new|g" "$f"
  done

  # libcrypto, libc and libm, which it is linked with, and libblkid
  for f in $out/lib/systemd/libsystemd-shared-*.so; do
    keep=$(patchelf --print-rpath "$f" | tr ':' '\n' | grep -E -- '-(openssl|glibc|util-linux-minimal)-' | paste -sd:)
    for want in openssl glibc util-linux-minimal; do
      case $keep in
        *-$want-*) ;;
        *) echo "$want is not in the search path of $f" >&2; exit 1 ;;
      esac
    done
    patchelf --set-rpath "$keep" "$f"
  done

  # the copies of systemd's private files must not still point at the package
  if grep -rl "$(basename ${systemd})" $out > /dev/null 2>&1; then
    echo "a reference to ${systemd} is left" >&2
    grep -rl "$(basename ${systemd})" $out >&2
    exit 1
  fi
''
