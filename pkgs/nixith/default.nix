# nixith: the system's tool for building it (nixith switch, nixith switch
# --only ...) and its other tools under one name; see nixith.sh and
# ../../lib/nixith.nix.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  gnused,
  gawk,
  jq,
  nix,
  s6,
  s6-rc,
  dinit,
  # (unit-rc, which runit's services are asked through)
  nixithos,
  # the console list of units (nixith services)
  nixith-services,
  # the tree and the nixpkgs under it, which systems are evaluated with
  tree,
  nixpkgs,
  # the tools nixith stands in front of
  nixos-install,
  nixos-enter,
  nixos-option,
  nixos-generate-config,
}:

replaceVarsWith {
  name = "nixith";
  src = ./nixith.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      gnused
      gawk
      jq
      nix
      nixos-install
      nixos-enter
      nixos-option
      nixos-generate-config
    ];
    inherit tree nixpkgs;
    services = nixith-services;
    # (by name: dinit's package has its own poweroff and reboot, which must
    # not come before the system's in what nixith runs)
    s6svstat = "${s6}/bin/s6-svstat";
    s6rc = "${s6-rc}/bin/s6-rc";
    dinitctl = "${dinit}/bin/dinitctl";
    rcctl = "${nixithos.unitTools}/bin/unit-rc";
    openrcctl = "${nixithos.openrcCtl}/bin/openrcctl";
    ux = "${./ux.sh}";
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
    ${bash}/bin/bash -n ${./ux.sh}
    # (scripts, not links to nixith: pkexec runs what a link points at, and
    # nixith would no longer know by its name what it was called as)
    for name in install generate-config enter option version rebuild; do
      printf '#!%s\nexec %s %s "$@"\n' ${bash}/bin/bash $target $name > $out/bin/nixith-$name
      chmod +x $out/bin/nixith-$name
    done
  '';

  meta = {
    description = "Builds NixithOS systems, whole or part by part";
    mainProgram = "nixith";
    platforms = lib.platforms.linux;
  };
}
