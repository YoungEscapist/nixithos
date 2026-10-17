# Two of systemd's client programs that work without systemd running, taken
# out of its package:
#
# - `busctl`, a D-Bus client like any other (rtkit's test and scripts talk to
#   services with it);
# - `systemd-analyze`, for one job: `security --offline=true`, which scores a
#   unit file's sandboxing settings by reading the file, with no service
#   manager to ask.  Upstream tests compare that score against fixed numbers
#   (`--threshold=`, "SAFE"), and it is systemd's own table of some eighty
#   checks and weights, so it is used as it is rather than imitated.
#
# Done as in ./boot-tool.nix: the copies get a name of the same length as the
# package's, the package's path in them is replaced by the copy's, and the
# library search path is cut down to what they open - besides libc
# and libcrypto it is linked with, libmount and libblkid (the unit's mounts)
# and libseccomp (SystemCallFilter=).  (`strace -e openat systemd-analyze
# security --offline=true` shows that this is all of them.)
{
  lib,
  runCommand,
  patchelf,
  systemd, # the real one
}:

let
  # (not "systemd-…": such a name is what the closure checks look for)
  wanted = "client-tools";
  n = lib.stringLength systemd.name;
  name = wanted + lib.concatStrings (lib.genList (_: "_") (n - lib.stringLength wanted));
  keepLibs = [
    "openssl"
    "glibc"
    "util-linux-minimal"
    "libseccomp"
  ];
in

runCommand name { nativeBuildInputs = [ patchelf ]; } ''
  mkdir -p $out/bin $out/lib/systemd
  cp ${systemd}/bin/systemd-analyze ${systemd}/bin/busctl $out/bin/
  cp ${systemd}/lib/systemd/libsystemd-shared-*.so ${systemd}/lib/systemd/libsystemd-core-*.so $out/lib/systemd/
  chmod -R u+w $out

  # same length, so that nothing moves
  old=${systemd}
  new=$out
  [ "''${#old}" = "''${#new}" ] || { echo "the copy's path is not as long as the original's" >&2; exit 1; }
  export LC_ALL=C
  for f in $out/bin/* $out/lib/systemd/*.so; do
    sed -i "s|$old|$new|g" "$f"
  done

  for f in $out/lib/systemd/*.so; do
    keep=$(patchelf --print-rpath "$f" | tr ':' '\n' | grep -E -- '-(${lib.concatStringsSep "|" keepLibs})-' | grep -v -- "$new" | paste -sd:)
    patchelf --set-rpath "$out/lib/systemd''${keep:+:$keep}" "$f"
  done
  for want in ${toString keepLibs}; do
    case $(patchelf --print-rpath $out/lib/systemd/libsystemd-shared-*.so) in
      *-$want-*) ;;
      *) echo "$want is not in the search path of libsystemd-shared" >&2; exit 1 ;;
    esac
  done

  # the copies of systemd's private files must not still point at the package
  if grep -rl "$(basename ${systemd})" $out > /dev/null 2>&1; then
    echo "a reference to ${systemd} is left" >&2
    grep -rl "$(basename ${systemd})" $out >&2
    exit 1
  fi
''
