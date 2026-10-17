# The sandboxing directives of systemd.exec(5) that are applied: each unit
# below does something from inside its sandbox and writes down what happened,
# and the test script reads the verdicts.
{
  name = "sandbox";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      sh =
        name: text:
        pkgs.writeShellScript name ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.iproute2 pkgs.gnugrep pkgs.gawk ]}
          ${text}
        '';
      # (the output file is opened before the sandbox is set up, so that it
      # can be written whatever is read-only inside)
      unit = extra: script: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = script;
        } // extra;
      };
      out = name: { StandardOutput = "file:/run/sb-${name}.out"; };
      try = cmd: ''if ( ${cmd} ) 2>/dev/null; then echo yes; else echo no; fi'';
    in
    {
      imports = [ ./configs/minimal-node.nix ];

      systemd.tmpfiles.rules = [
        "d /var/lib/sb-rw 0755 root root -"
        "d /var/lib/sb-bindsrc 0755 root root -"
        "d /var/secret 0755 root root -"
        "f /var/secret/key 0644 root root - top"
        "d /srv/bound 0755 root root -"
        "f /srv/bound/file 0644 root root - bound"
        "d /run/sb-root 0755 root root -"
        "d /tmp/sb-shared 0755 root root -"
        "f /tmp/sb-shared/data 0644 root root - shared"
      ];

      systemd.services = {
        sb-tmp = unit (out "tmp" // { PrivateTmp = true; }) (sh "sb-tmp" ''
          touch /tmp/inside /var/tmp/inside-var
          ls /tmp /var/tmp
        '');

        # a directory of the real /tmp, bound into the private one (as the
        # bird of nixpkgs' flap-alerted test reads its routes)
        sb-tmp-bind = unit (
          out "tmp-bind"
          // {
            PrivateTmp = true;
            ProtectSystem = "strict";
            BindReadOnlyPaths = [ "/tmp/sb-shared" ];
          }
        ) (sh "sb-tmp-bind" ''
          echo "data: $(cat /tmp/sb-shared/data)"
          echo "private: $(${try "touch /tmp/mine"})"
          echo "bound-ro: $(${try "touch /tmp/sb-shared/x"})"
        '');

        sb-strict = unit (
          out "strict"
          // {
            ProtectSystem = "strict";
            ReadWritePaths = [ "/var/lib/sb-rw" ];
            # (a bind stays writable, as wpa_supplicant's does)
            BindPaths = [ "/var/lib/sb-bindsrc:/srv/sb-bind" ];
          }
        ) (sh "sb-strict" ''
          echo "bind: $(${try "touch /srv/sb-bind/x"})"
          echo "etc: $(${try "touch /etc/sb-x"})"
          echo "run: $(${try "touch /run/sb-x"})"
          echo "varlib: $(${try "touch /var/lib/sb-x"})"
          echo "rw: $(${try "touch /var/lib/sb-rw/x"})"
          echo "dev: $(${try "touch /dev/sb-x"})"
          echo "proc: $(${try "test -r /proc/self/status"})"
        '');

        sb-full = unit (out "full" // { ProtectSystem = "full"; }) (sh "sb-full" ''
          echo "etc: $(${try "touch /etc/sb-x"})"
          echo "varlib: $(${try "touch /var/lib/sb-x"})"
          rm -f /var/lib/sb-x
        '');

        sb-home = unit (out "home" // { ProtectHome = true; }) (sh "sb-home" ''
          echo "root: $(${try "ls /root/x"})"
          echo "list: $(ls -A /root /home | tr '\n' ' ')"
        '');

        sb-home-ro = unit (out "home-ro" // { ProtectHome = "read-only"; }) (sh "sb-home-ro" ''
          echo "write: $(${try "touch /root/sb-x"})"
          echo "read: $(${try "ls /root"})"
        '');

        # "+": full privileges, the namespaces are not applied to it (but they
        # are to ExecStart=)
        sb-plus = unit (
          out "plus"
          // {
            ProtectSystem = "strict";
            PrivateTmp = true;
            ExecStartPre = "+${sh "sb-plus-pre" "touch /etc/sb-plus-pre /tmp/sb-plus-pre"}";
          }
        ) (sh "sb-plus" ''
          echo "etc: $(${try "touch /etc/sb-plus-main"})"
          echo "pre-etc: $(test -e /etc/sb-plus-pre && echo yes || echo no)"
          echo "pre-tmp: $(test -e /tmp/sb-plus-pre && echo yes || echo no)"
        '');

        sb-dev = unit (out "dev" // { PrivateDevices = true; }) (sh "sb-dev" ''
          echo "null: $(${try "echo x > /dev/null"})"
          echo "vda: $(${try "test -e /dev/vda"})"
          echo "log: $(${try "test -S /dev/log"})"
          echo "listing: $(ls /dev | tr '\n' ' ')"
        '');

        sb-net = unit (out "net" // { PrivateNetwork = true; }) (sh "sb-net" ''
          echo "links: $(ip -br link | awk '{print $1}' | tr '\n' ' ')"
        '');

        sb-paths = unit (
          out "paths"
          // {
            ReadOnlyPaths = [ "/var/lib/sb-rw" ];
            InaccessiblePaths = [ "/var/secret" ];
            BindReadOnlyPaths = [ "/srv/bound:/mnt" ];
            TemporaryFileSystem = [ "/opt" ];
          }
        ) (sh "sb-paths" ''
          echo "ro: $(${try "touch /var/lib/sb-rw/x"})"
          echo "secret: $(${try "cat /var/secret/key"})"
          echo "bound: $(cat /mnt/file 2>/dev/null)"
          echo "bound-rw: $(${try "touch /mnt/x"})"
          echo "tmpfs: $(${try "touch /opt/x"})"
        '');

        # the working directory is a state directory: written to through the
        # mount that made it writable, not the read-only one under it
        sb-workdir = unit (
          out "workdir"
          // {
            ProtectSystem = "strict";
            StateDirectory = "sb-wd";
            WorkingDirectory = "/var/lib/sb-wd";
          }
        ) (sh "sb-workdir" ''
          echo "cwd: $(pwd)"
          echo "write: $(${try "touch ./from-cwd"})"
        '');

        sb-dynamic = unit (
          out "dynamic"
          // {
            DynamicUser = true;
            StateDirectory = "sb-dyn";
          }
        ) (sh "sb-dynamic" ''
          echo "uid: $(id -u)"
          echo "state: $(${try "touch /var/lib/sb-dyn/x"})"
          echo "etc: $(${try "touch /etc/sb-x"})"
          echo "tmp: $(${try "touch /tmp/sb-dyn-x"})"
        '');

        # a root directory of its own: the store, /proc and nothing else
        sb-root = unit (
          out "root"
          // {
            RootDirectory = "/run/sb-root";
            RootDirectoryStartOnly = true;
            BindReadOnlyPaths = [
              builtins.storeDir
              # a file, where the root has no directory for it (wpa_supplicant's secrets)
              "/var/secret/key:/srv/k/key"
            ];
            MountAPIVFS = true;
            User = "nobody";
            WorkingDirectory = "/nix";
            # (for the files the command makes, not for the root's mount
            # points: wpa_supplicant's module has this)
            UMask = "0077";
            # the directories of the unit are in its root, as outside it
            RuntimeDirectory = "sb-root-rt";
            # (made by root, under the UMask= too: readable by the user only
            # because it is said so)
            ExecStartPre = "+${sh "sb-root-pre" "echo outside > /run/sb-root-rt/from-outside; chmod 644 /run/sb-root-rt/from-outside"}";
          }
        ) (sh "sb-root" ''
          echo inside > /run/sb-root-rt/from-inside
          echo "rt: $(cat /run/sb-root-rt/from-outside 2>/dev/null || echo missing)"
          echo "uid: $(id -u)"
          echo "list: $(ls / | tr '\n' ' ')"
          echo "etc: $(${try "test -e /etc/passwd"})"
          echo "store: $(${try "test -d ${builtins.storeDir}"})"
          echo "proc: $(${try "test -r /proc/self/status"})"
          echo "cwd: $(pwd)"
          echo "file: $(cat /srv/k/key 2>/dev/null || echo missing)"
          grep CapEff /proc/self/status
        '');

        # root, with no capabilities left at all (gonic's module): the root
        # directory is entered before they are gone
        sb-root-nocaps = unit (
          out "root-nocaps"
          // {
            RootDirectory = "/run/sb-root";
            BindReadOnlyPaths = [ builtins.storeDir ];
            CapabilityBoundingSet = "";
          }
        ) (sh "sb-root-nocaps" ''
          echo "uid: $(id -u)"
          grep CapBnd /proc/self/status
        '');

        sb-caps = unit (
          out "caps"
          // {
            ProtectKernelModules = true;
            ProtectClock = true;
          }
        ) (sh "sb-caps" ''
          grep CapBnd /proc/self/status
        '');

        sb-tunables = unit (
          out "tunables"
          // {
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
          }
        ) (sh "sb-tunables" ''
          echo "sysctl: $(${try "echo 1 > /proc/sys/vm/swappiness"})"
          echo "cgroup: $(${try "mkdir /sys/fs/cgroup/sb-x"})"
          echo "read: $(${try "cat /proc/sys/vm/swappiness >/dev/null"})"
        '');
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def verdicts(name):
        lines = machine.succeed(f"cat /run/sb-{name}.out").strip().splitlines()
        print(name, lines)
        return dict(l.split(": ", 1) for l in lines if ": " in l)

    with subtest("PrivateTmp"):
        out = machine.succeed("cat /run/sb-tmp.out")
        assert "inside" in out and "inside-var" in out, out
        machine.fail("test -e /tmp/inside || test -e /var/tmp/inside-var")
        v = verdicts("tmp-bind")
        assert v["data"] == "shared" and v["private"] == "yes" and v["bound-ro"] == "no", v
        machine.fail("test -e /tmp/mine")

    with subtest("ProtectSystem=strict and ReadWritePaths"):
        v = verdicts("strict")
        assert v["etc"] == "no" and v["run"] == "no" and v["varlib"] == "no", v
        assert v["rw"] == "yes" and v["proc"] == "yes" and v["bind"] == "yes", v
        machine.succeed("test -e /var/lib/sb-bindsrc/x")
        machine.succeed("test -e /var/lib/sb-rw/x")

    with subtest("ProtectSystem=full"):
        v = verdicts("full")
        assert v["etc"] == "no" and v["varlib"] == "yes", v

    with subtest("ProtectHome"):
        v = verdicts("home")
        assert v["root"] == "no", v
        v = verdicts("home-ro")
        assert v["write"] == "no" and v["read"] == "yes", v
        machine.fail("test -e /root/sb-x")

    with subtest("a command with + is not sandboxed"):
        v = verdicts("plus")
        assert v["etc"] == "no", v
        # it wrote in /etc, which the unit cannot, and in the real /tmp
        assert v["pre-etc"] == "yes" and v["pre-tmp"] == "no", v
        machine.succeed("test -e /etc/sb-plus-pre && test -e /tmp/sb-plus-pre")

    with subtest("PrivateDevices"):
        v = verdicts("dev")
        assert v["null"] == "yes" and v["vda"] == "no", v
        assert "null" in v["listing"] and "zero" in v["listing"], v
        # syslog(3) still has somewhere to go
        assert v["log"] == "yes", v
        # the host's /dev is as it was
        machine.succeed("test -e /dev/vda")

    with subtest("PrivateNetwork"):
        v = verdicts("net")
        assert v["links"].split() == ["lo"], v
        machine.succeed("ip -br link | grep -q eth")

    with subtest("ReadOnlyPaths, InaccessiblePaths, BindReadOnlyPaths, TemporaryFileSystem"):
        v = verdicts("paths")
        assert v["ro"] == "no", v
        assert v["secret"] == "no", v
        assert v["bound"] == "bound" and v["bound-rw"] == "no", v
        assert v["tmpfs"] == "yes", v
        machine.succeed("cat /var/secret/key")
        machine.fail("test -e /opt/x")

    with subtest("a working directory made writable"):
        v = verdicts("workdir")
        assert v["cwd"] == "/var/lib/sb-wd" and v["write"] == "yes", v
        machine.succeed("test -e /var/lib/sb-wd/from-cwd")

    with subtest("DynamicUser implies a sandbox"):
        v = verdicts("dynamic")
        assert int(v["uid"]) > 0, v
        assert v["state"] == "yes" and v["etc"] == "no" and v["tmp"] == "yes", v
        machine.fail("test -e /tmp/sb-dyn-x")
        # and is a user the rest of the system knows, as with nss-systemd
        entry = machine.succeed("getent passwd sb-dynamic").strip().split(":")
        assert entry[2] == v["uid"], (entry, v)
        assert machine.succeed("getent group sb-dynamic").strip().split(":")[2] == entry[3]

    with subtest("RootDirectory"):
        v = verdicts("root")
        assert int(v["uid"]) > 0, v
        assert v["etc"] == "no" and v["store"] == "yes" and v["proc"] == "yes", v
        assert "nix" in v["list"] and "etc" not in v["list"].split(), v
        assert v["cwd"] == "/nix", v
        assert v["rt"] == "outside", v
        assert v["file"] == "top", v
        assert machine.succeed("cat /run/sb-root-rt/from-inside").strip() == "inside"
        # nothing is left of the capability that made the chroot
        assert "CapEff:\t0000000000000000" in machine.succeed("cat /run/sb-root.out")
        v = verdicts("root-nocaps")
        assert v.get("uid") == "0", v
        assert "CapBnd:\t0000000000000000" in machine.succeed("cat /run/sb-root-nocaps.out")

    with subtest("capabilities taken away"):
        out = machine.succeed("cat /run/sb-caps.out")
        # CAP_SYS_MODULE is 16, CAP_SYS_TIME 25
        bnd = int(out.split()[-1], 16)
        assert bnd & (1 << 16) == 0 and bnd & (1 << 25) == 0, out
        assert bnd & (1 << 0) != 0, out

    with subtest("ProtectKernelTunables, ProtectControlGroups"):
        v = verdicts("tunables")
        assert v["sysctl"] == "no" and v["cgroup"] == "no" and v["read"] == "yes", v
  '';
}
