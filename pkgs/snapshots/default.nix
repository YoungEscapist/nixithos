# nixith-snapshots: read-only btrfs snapshots of the system before each
# switch; see the script and ../../modules/system/snapshots.nix.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  gnused,
  btrfs-progs,
  util-linux,
  # where the snapshots go, how many are kept, which subvolumes are taken
  dir ? "/.snapshots",
  keep ? 10,
  paths ? [
    "/"
    "/home"
  ],
}:

replaceVarsWith {
  name = "nixith-snapshots";
  src = ./snapshots.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      gnused
      btrfs-progs
      util-linux
    ];
    dir = lib.escapeShellArg dir;
    keep = toString keep;
    paths = lib.escapeShellArgs paths;
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "Read-only btrfs snapshots of the system before each switch";
    mainProgram = "nixith-snapshots";
    platforms = lib.platforms.linux;
  };
}
