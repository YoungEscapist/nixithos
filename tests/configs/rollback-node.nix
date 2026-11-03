# What the boot assessment tests (rollback-*.nix) have in common: a node
# installed on a disk, booted through its boot loader, with boot assessment
# on and three more systems inside it to make generations of:
#
#   reset   resets the machine in stage 2, before the init system starts
#   unit    boots, but a unit that its boot requires fails
#   fine    boots, with a mark in /etc
{ lib, pkgs, ... }:

{
  imports = [ ./minimal-node.nix ];

  s6.systemdPackages = "replace";
  virtualisation.useBootLoader = true;
  boot.loader.timeout = 0;

  nixithos.bootAssessment.enable = true;

  specialisation = {
    reset.configuration = {
      boot.postBootCommands = ''
        echo 1 > /proc/sys/kernel/sysrq
        echo b > /proc/sysrq-trigger
      '';
    };

    unit.configuration = {
      systemd.services.canary = {
        description = "A unit that does not start";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = "exit 1";
      };
      nixithos.bootAssessment.requiredUnits = [ "canary.service" ];
    };

    fine.configuration = {
      environment.etc."rollback-marker".text = "fine\n";
    };
  };
}
