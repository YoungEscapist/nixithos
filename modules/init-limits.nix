# s6.init.limits is in the letters of s6-softlimit; for the inits that are
# not s6 they become the shell's ulimit commands, run before they start (the
# hard limits of PID 1, inherited by everything).
{ lib }:

spec:

let
  ulimitFlags = {
    a = [ "v" ];
    c = [ "c" ];
    d = [ "d" ];
    f = [ "f" ];
    l = [ "l" ];
    m = [
      "d"
      "s"
      "l"
      "v"
    ];
    o = [ "n" ];
    p = [ "u" ];
    r = [ "m" ];
    s = [ "s" ];
    t = [ "t" ];
  };
in
lib.concatMapStringsSep "\n" (
  item:
  let
    letter = builtins.substring 0 1 item;
    value = builtins.substring 1 (-1) item;
    flags = ulimitFlags.${letter} or (throw "s6.init.limits: unknown resource `${letter}' in `${item}'");
  in
  lib.concatMapStringsSep "\n" (
    f: "ulimit -H${f} ${if value == "=" then "unlimited" else value} 2>/dev/null"
  ) flags
) (lib.filter (x: x != "") (lib.splitString "," spec))
