{ lib, replaceVarsWith, bash, coreutils, gnugrep, jq, util-linux, nixithos }:
replaceVarsWith {
  name = "finitctl";
  src = ./finitctl.sh;
  dir = "bin";
  isExecutable = true;
  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [ coreutils gnugrep jq util-linux ];
    initctl = "${nixithos.finit}/sbin/initctl";
  };
  postInstall = "${bash}/bin/bash -n $target";
}
