# nixpkgs' replaceDirectDependencies, with one change: the hash of an old path
# is replaced wherever it stands, not only as part of the path's whole name.
#
# The original rewrites `<hash>-<name>` and nothing else.  Some packages have
# the hash of their own path (or another's) in a form that is not that:
# gtk4's library has `<hash>-gtk4k4-4.22.5/share` in it, from a string the
# linker shared between two others.  Nix finds a reference by the hash alone,
# so the rewritten copy of such a package refers to the original one, and with
# it to everything that was to be replaced.  Replacing the hash too makes the
# stray occurrence point at the new path, as it would have pointed at the old.
#
# The hash is replaced in UTF-16 (little-endian) as well: Qt programs keep
# paths fixed at build time as QStringLiteral, UTF-16 in the binary.
# lxqt-panel looks up its plugins by its own path written so; rewritten in
# UTF-8 only, it went on looking in the original, which is not in the system,
# and its panel came up with no plugins at all.  (Nix finds no reference in
# UTF-16, so the original was never kept alive by it.)
{
  lib,
  runCommandLocal,
  nix,
}:

{
  drv,
  replacements ? [ ],
}:
let
  inherit (lib)
    isStringLike
    substring
    stringLength
    optionalString
    escapeShellArgs
    concatMap
    ;

  isNonCaStorePath =
    x:
    if isStringLike x then
      let
        str = toString x;
      in
      builtins.substring 0 1 str == "/" && (dirOf str == builtins.storeDir)
    else
      false;
in
if replacements == [ ] then
  drv
else
  let
    drvName =
      if isNonCaStorePath drv then
        # Reconstruct the name from the actual store path if available.
        substring 33 (stringLength (baseNameOf drv)) (baseNameOf drv)
      else if drv ? drvAttrs.name then
        # Try to get the name from the derivation arguments otherwise (for floating or deferred derivations).
        drv.drvAttrs.name
        + (
          let
            outputName = drv.outputName or "out";
          in
          optionalString (outputName != "out") "-${outputName}"
        )
      else
        throw "cannot reconstruct the derivation name from ${drv}";
  in
  runCommandLocal drvName { nativeBuildInputs = [ nix.out ]; } ''
    # a sed pattern for the UTF-16LE form of an ASCII string
    utf16() {
        printf '%s' "$1" | sed 's/./&\\x00/g; s/\\x00$//'
    }
    createRewriteScript() {
        while [ $# -ne 0 ]; do
            oldBasename="$(basename "$1")"
            newBasename="$(basename "$2")"
            shift 2
            if [ ''${#oldBasename} -ne ''${#newBasename} ]; then
                echo "cannot rewrite $oldBasename to $newBasename: length does not match" >&2
                exit 1
            fi
            echo "s|$oldBasename|$newBasename|g" >> rewrite.sed
            # what is left of the old hash, in strings that are not the name
            echo "s|''${oldBasename:0:32}|''${newBasename:0:32}|g" >> rewrite.sed
            # ... and the hash in UTF-16, a NUL after every character
            echo "s|$(utf16 "''${oldBasename:0:32}")|$(utf16 "''${newBasename:0:32}")|g" >> rewrite.sed
        done
    }
    createRewriteScript ${
      escapeShellArgs (
        [
          drv
          (placeholder "out")
        ]
        ++ concatMap (
          { oldDependency, newDependency }:
          [
            oldDependency
            newDependency
          ]
        ) replacements
      )
    }
    nix-store --dump ${drv} | sed -f rewrite.sed | nix-store --restore $out
  ''
