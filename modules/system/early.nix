# What systemd does by itself when it starts as PID 1, before any unit runs,
# and which therefore appears in no NixOS module: mounting the kernel's API
# file systems, bringing up the loopback interface, raising resource limits.
# (Naming the machine and creating /etc/machine-id happen even earlier, in
# stage 2.)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  apiMount =
    {
      where,
      type,
      options ? "nosuid,nodev,noexec",
      condition ? where,
      after ? [ ],
    }:
    {
      what = type;
      inherit where type options;
      wantedBy = [ "sysinit.target" ];
      before = [ "sysinit.target" ];
      inherit after;
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = condition;
      };
    };
in

{
  options.s6.init.limits = lib.mkOption {
    type = lib.types.str;
    default = "o524288";
    example = "o1048576,c=";
    description = ''
      Hard resource limits of PID 1, inherited by everything, in the notation
      of s6-linux-init-maker's `-R` option: a comma-separated list of a
      letter as for s6-softlimit (`o` is the number of open files) followed
      by a value, or by `=` for "unlimited".  The kernel's own hard limit for
      open files is 4096, which is too low for many programs; systemd raises
      it to the value used here.
    '';
  };

  config = {
    systemd.mounts = lib.optionals (!config.boot.isContainer) (
      map apiMount [
        {
          where = "/dev/mqueue";
          type = "mqueue";
          condition = "/proc/sys/fs/mqueue";
        }
        {
          where = "/dev/hugepages";
          type = "hugetlbfs";
          options = "nosuid,nodev";
          condition = "/sys/kernel/mm/hugepages";
        }
        {
          where = "/sys/kernel/security";
          type = "securityfs";
        }
        {
          where = "/sys/kernel/config";
          type = "configfs";
          after = [ "systemd-modules-load.service" ];
        }
        {
          where = "/sys/kernel/debug";
          type = "debugfs";
        }
        {
          where = "/sys/kernel/tracing";
          type = "tracefs";
        }
        {
          where = "/sys/fs/fuse/connections";
          type = "fusectl";
          after = [ "systemd-modules-load.service" ];
        }
        {
          where = "/sys/fs/pstore";
          type = "pstore";
        }
        {
          where = "/sys/fs/bpf";
          type = "bpf";
          options = "nosuid,nodev,noexec,mode=700";
        }
        {
          where = "/sys/firmware/efi/efivars";
          type = "efivarfs";
        }
      ]
    );

    systemd.services.loopback = {
      description = "Loopback Network Interface";
      wantedBy = [ "sysinit.target" ];
      before = [
        "sysinit.target"
        "network-pre.target"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.iproute2}/bin/ip link set lo up";
      };
    };

    # Without systemd-coredump, cores go where the kernel puts them.
    boot.kernel.sysctl."kernel.core_pattern" = lib.mkDefault "core";
  };
}
