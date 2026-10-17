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
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
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
