# Mount and swap units for `fileSystems` and `swapDevices`.
#
# systemd creates these at boot, by running a generator over /etc/fstab.
# Here the service database is compiled when the system is built, so the
# same translation is done at evaluation time.  /etc/fstab is still written
# (by nixos/modules/tasks/filesystems.nix), for mount(8) and for people.
{
  config,
  lib,
  utils,
  ...
}:

let
  inherit (utils) escapeSystemdPath fsNeededForBoot;

  networkTypes = [
    "nfs"
    "nfs4"
    "cifs"
    "smb3"
    "ceph"
    "glusterfs"
    "sshfs"
    "fuse.sshfs"
    "9p"
    "davfs"
    "ncpfs"
    "iscsi"
  ];

  # Everything that is not virtual is checked before it is mounted, as
  # systemd-fsck@ would do it.
  noFsck = [
    "auto"
    "tmpfs"
    "ramfs"
    "proc"
    "sysfs"
    "devtmpfs"
    "devpts"
    "overlay"
    "squashfs"
    "erofs"
    "9p"
    "virtiofs"
    "zfs"
    "btrfs"
    "bcachefs"
    "xfs"
    "fuse"
    "none"
  ]
  ++ networkTypes;

  device = fs: if fs.device != null then fs.device else "/dev/disk/by-label/${fs.label}";

  # File systems needed for boot are mounted by the initrd and stay that way.
  mountedLater = lib.filter (fs: !(fsNeededForBoot fs)) config.system.build.fileSystems;

  mountUnit =
    fs:
    let
      has = opt: lib.elem opt fs.options;
      remote = has "_netdev" || lib.elem fs.fsType networkTypes;
      target = if remote then "remote-fs.target" else "local-fs.target";
      auto = !(has "noauto");
      # nofail: a missing device must not hold up the boot
      optional = has "nofail";
      isBind = has "bind" || has "rbind";
      check = !fs.noCheck && !isBind && lib.hasPrefix "/dev/" (device fs) && !(lib.elem fs.fsType noFsck);
    in
    {
      what = device fs;
      where = fs.mountPoint;
      type = fs.fsType;
      options = lib.concatStringsSep "," fs.options;
      wantedBy = lib.optional (auto && optional) target;
      requiredBy = lib.optional (auto && !optional) target;
      before = [ target ];
      after = lib.optionals remote [
        "network-online.target"
        "network.target"
      ];
      wants = lib.optional remote "network-online.target";
      mountConfig = lib.optionalAttrs check { X-Fsck = true; };
    };

  swapUnit = sw: {
    name = "${escapeSystemdPath sw.realDevice}.swap";
    value = {
      wantedBy = [ "swap.target" ];
      text = ''
        [Unit]
        Description=Swap on ${sw.realDevice}
        DefaultDependencies=no
        Before=swap.target

        [Swap]
        What=${sw.realDevice}
        ${lib.optionalString (sw.priority != null) "Priority=${toString sw.priority}"}
        Options=${
          lib.concatStringsSep "," (
            sw.options
            ++ lib.optional (sw.discardPolicy != null) (
              "discard" + lib.optionalString (sw.discardPolicy != "both") "=${toString sw.discardPolicy}"
            )
          )
        }
      '';
    };
  };
in

{
  config = {
    systemd.mounts = map mountUnit mountedLater;
    systemd.units = lib.listToAttrs (map swapUnit config.swapDevices);
  };
}
