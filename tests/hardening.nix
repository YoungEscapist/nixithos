# The protection of services that nixpkgs' modules expect of systemd: system
# call filters and the restrictions made of them (unit-seccomp), resource
# limits in the control group of the unit, /proc with hidden processes, and
# the warning at build time about what is asked for and not given.
#
# Each unit below does something from inside its restrictions and writes down
# what happened; the test script reads the verdicts.  The same test runs on
# both init systems (-A tests.hardening, -A dinit.hardening).
{
  name = "hardening";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      probe = pkgs.writeCBin "hd-probe" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <sched.h>
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/mman.h>
        #include <sys/personality.h>
        #include <sys/socket.h>
        #include <sys/stat.h>
        #include <sys/syscall.h>
        #include <sys/wait.h>
        #include <linux/netlink.h>
        #include <unistd.h>

        static void res(const char *what, long r) {
          if (r >= 0) printf("%s: ok\n", what);
          else printf("%s: errno=%d\n", what, errno);
          fflush(stdout);
        }

        int main(int argc, char **argv) {
          const char *m = argc > 1 ? argv[1] : "";
          char what[64];
          snprintf(what, sizeof what, "%s%s%s", m, argc > 2 ? " " : "", argc > 2 ? argv[2] : "");
          if (!strcmp(m, "mmap-rwx")) {
            void *p = mmap(0, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            res(what, p == MAP_FAILED ? -1 : 0);
          } else if (!strcmp(m, "mprotect-x")) {
            void *p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            res(what, mprotect(p, 4096, PROT_READ | PROT_EXEC));
          } else if (!strcmp(m, "personality")) {
            res(what, personality(PER_LINUX32));
          } else if (!strcmp(m, "sched-fifo")) {
            struct sched_param sp = { 1 };
            res(what, sched_setscheduler(0, SCHED_FIFO, &sp));
          } else if (!strcmp(m, "unshare")) {
            int f = !strcmp(argv[2], "uts") ? CLONE_NEWUTS : !strcmp(argv[2], "net") ? CLONE_NEWNET : CLONE_NEWIPC;
            res(what, unshare(f));
          } else if (!strcmp(m, "socket")) {
            int af = !strcmp(argv[2], "unix") ? AF_UNIX : !strcmp(argv[2], "inet") ? AF_INET : AF_NETLINK;
            int type = af == AF_NETLINK ? SOCK_RAW : SOCK_DGRAM;
            res(what, socket(af, type, 0));
          } else if (!strcmp(m, "chmod")) {
            res(what, chmod(argv[3], strtol(argv[2], 0, 8)));
          } else if (!strcmp(m, "sys")) {
            /* system calls that do nothing to the machine when they get there */
            long r = -1;
            if (!strcmp(argv[2], "getpriority")) r = syscall(SYS_getpriority, 0, 0);
            else if (!strcmp(argv[2], "chroot")) r = syscall(SYS_chroot, "/nonexistent");
            else if (!strcmp(argv[2], "reboot")) r = syscall(SYS_reboot, 0, 0, 0, 0);
            res(what, r);
          } else if (!strcmp(m, "alloc")) {
            size_t n = (size_t)atoi(argv[2]) << 20;
            char *p = malloc(n);
            if (!p) { res(what, -1); return 1; }
            for (size_t i = 0; i < n; i += 4096) p[i] = 1;
            res(what, 0);
          } else if (!strcmp(m, "forks")) {
            int n = atoi(argv[2]), made = 0;
            pid_t kids[512];
            for (int i = 0; i < n && i < 512; i++) {
              pid_t p = fork();
              if (p == 0) { pause(); _exit(0); }
              if (p < 0) break;
              kids[made++] = p;
            }
            printf("%s: %d\n", what, made);
            fflush(stdout);
            for (int i = 0; i < made; i++) kill(kids[i], SIGKILL);
            for (int i = 0; i < made; i++) waitpid(kids[i], 0, 0);
          } else {
            fprintf(stderr, "usage\n");
            return 2;
          }
          return 0;
        }
      '';
      p = "${probe}/bin/hd-probe";
      sh =
        name: text:
        pkgs.writeShellScript name ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gawk
            ]
          }
          exec 2>&1
          ${text}
        '';
      # (the output file is opened before the restrictions are in place)
      unit = extra: script: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = script;
        } // extra;
      };
      out = name: { StandardOutput = "file:/run/hd-${name}.out"; };
      # the control group of the unit, as the unit sees it
      cgroup = ''
        cg=/sys/fs/cgroup$(awk -F:: '/^0::/{print $2}' /proc/self/cgroup)
        echo "cgroup: $cg"
      '';
    in
    {
      imports = [ ./configs/minimal-node.nix ];

      virtualisation.memorySize = 1536;
      # (the test machines panic at the first out-of-memory kill, of a
      # control group as well; the limit is to kill the process)
      boot.kernel.sysctl."vm.panic_on_oom" = lib.mkForce 0;

      environment.etc."hd-file".text = "x";
      systemd.tmpfiles.rules = [ "d /run/hd-root 0755 root root -" ];

      systemd.services = {
        # a system call that is refused kills the process (SIGSYS, 128+31)
        hd-kill = unit (out "kill" // { SystemCallFilter = "~getpriority"; }) (sh "hd-kill" ''
          echo "before: ok"
          ${p} sys getpriority
          echo "rc: $?"
          ${p} sys reboot
        '');

        # …or fails with an error: for one name, or for all
        hd-errno = unit (
          out "errno"
          // {
            SystemCallFilter = [
              "~getpriority:EPERM"
              "chroot:EACCES"
            ];
          }
        ) (sh "hd-errno" ''
          ${p} sys getpriority
          ${p} sys chroot
        '');
        hd-errno-default = unit (
          out "errno-default"
          // {
            SystemCallFilter = "~getpriority";
            SystemCallErrorNumber = "EACCES";
          }
        ) (sh "hd-errno-default" ''
          ${p} sys getpriority
        '');

        # groups: what a service needs, without what is for the privileged
        hd-groups = unit (
          out "groups"
          // {
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
            ];
          }
        ) (sh "hd-groups" ''
          echo "shell: ok"
          cat /etc/hd-file
          ${p} sys getpriority
          ${p} forks 3
          ${p} sys chroot
          echo "rc: $?"
        '');

        # an allow list: reboot(2) is not in it
        hd-allow = unit (out "allow" // { SystemCallFilter = "@system-service"; }) (sh "hd-allow" ''
          ${p} sys getpriority
          ${p} sys reboot
          echo "rc: $?"
        '');

        # a command with + is not restricted
        hd-plus = unit (
          out "plus"
          // {
            SystemCallFilter = "~getpriority";
            ExecStartPre = "+${sh "hd-plus-pre" "${p} sys getpriority > /run/hd-plus-pre.out"}";
          }
        ) (sh "hd-plus" ''
          ${p} sys getpriority
          echo "rc: $?"
        '');

        # no_new_privs comes with a filter, unless the process is the system's
        hd-nnp-user = unit (
          out "nnp-user"
          // {
            SystemCallFilter = "~getpriority";
            User = "nobody";
          }
        ) (sh "hd-nnp-user" ''
          echo "nnp: $(awk '/^NoNewPrivs/{print $2}' /proc/self/status)"
        '');
        hd-nnp-root = unit (out "nnp-root" // { SystemCallFilter = "~getpriority"; }) (sh "hd-nnp-root" ''
          echo "nnp: $(awk '/^NoNewPrivs/{print $2}' /proc/self/status)"
        '');

        hd-arch = unit (
          out "arch"
          // {
            SystemCallArchitectures = "native";
            SystemCallFilter = "@system-service";
          }
        ) (sh "hd-arch" ''
          echo "ran: ok"
          ${p} sys getpriority
        '');

        # the filter of a unit that has a root directory of its own is loaded
        # by unit-chroot: there is no unit-seccomp in that root
        hd-rooted = unit (
          out "rooted"
          // {
            RootDirectory = "/run/hd-root";
            BindReadOnlyPaths = [ builtins.storeDir ];
            SystemCallFilter = "~getpriority";
            MemoryDenyWriteExecute = true;
            User = "nobody";
          }
        ) (sh "hd-rooted" ''
          echo "uid: $(id -u)"
          ${p} sys getpriority
          echo "rc: $?"
          ${p} mmap-rwx
        '');

        hd-af-unix = unit (out "af-unix" // { RestrictAddressFamilies = "AF_UNIX"; }) (sh "hd-af-unix" ''
          ${p} socket unix
          ${p} socket inet
          ${p} socket netlink
        '');
        hd-af-deny = unit (out "af-deny" // { RestrictAddressFamilies = "~AF_INET AF_INET6"; }) (sh "hd-af-deny" ''
          ${p} socket unix
          ${p} socket inet
          ${p} socket netlink
        '');
        hd-af-free = unit (out "af-free" // { }) (sh "hd-af-free" ''
          ${p} socket inet
          ${p} socket netlink
        '');

        hd-mdwe = unit (out "mdwe" // { MemoryDenyWriteExecute = true; }) (sh "hd-mdwe" ''
          ${p} mmap-rwx
          ${p} mprotect-x
        '');
        hd-mdwe-free = unit (out "mdwe-free" // { }) (sh "hd-mdwe-free" ''
          ${p} mmap-rwx
          ${p} mprotect-x
        '');

        hd-lock = unit (out "lock" // { LockPersonality = true; }) (sh "hd-lock" ''
          ${p} personality
        '');
        hd-lock-free = unit (out "lock-free" // { }) (sh "hd-lock-free" ''
          ${p} personality
        '');

        hd-rt = unit (out "rt" // { RestrictRealtime = true; }) (sh "hd-rt" ''
          ${p} sched-fifo
        '');
        hd-rt-free = unit (out "rt-free" // { }) (sh "hd-rt-free" ''
          ${p} sched-fifo
        '');

        hd-ns-all = unit (out "ns-all" // { RestrictNamespaces = true; }) (sh "hd-ns-all" ''
          ${p} unshare uts
          ${p} unshare net
        '');
        hd-ns-some = unit (out "ns-some" // { RestrictNamespaces = "uts"; }) (sh "hd-ns-some" ''
          ${p} unshare uts
          ${p} unshare net
        '');
        hd-ns-free = unit (out "ns-free" // { }) (sh "hd-ns-free" ''
          ${p} unshare uts
          ${p} unshare net
        '');

        hd-suid = unit (out "suid" // { RestrictSUIDSGID = true; }) (sh "hd-suid" ''
          touch /run/hd-suid-file
          ${p} chmod 4755 /run/hd-suid-file
          ${p} chmod 2755 /run/hd-suid-file
          ${p} chmod 0755 /run/hd-suid-file
        '');
        hd-suid-dynamic = unit (
          out "suid-dynamic"
          // {
            DynamicUser = true;
            RuntimeDirectory = "hd-dyn";
          }
        ) (sh "hd-suid-dynamic" ''
          touch /run/hd-dyn/f
          ${p} chmod 4755 /run/hd-dyn/f
        '');

        # resources of the control group
        hd-mem = unit (
          out "mem"
          // {
            MemoryMax = "64M";
            MemoryHigh = "48M";
            MemorySwapMax = "0";
          }
        ) (sh "hd-mem" ''
          ${cgroup}
          echo "max: $(cat $cg/memory.max)"
          echo "high: $(cat $cg/memory.high)"
          echo "swap: $(cat $cg/memory.swap.max)"
          ${p} alloc 8
          ${p} alloc 400
          echo "rc: $?"
          echo "oom_kill: $(awk '/^oom_kill /{print $2}' $cg/memory.events)"
        '');
        hd-cpu = unit (
          out "cpu"
          // {
            CPUQuota = "50%";
            CPUWeight = 200;
            IOWeight = 300;
          }
        ) (sh "hd-cpu" ''
          ${cgroup}
          echo "cpumax: $(cat $cg/cpu.max)"
          echo "weight: $(cat $cg/cpu.weight)"
          echo "io: $(cat $cg/io.weight 2>/dev/null || echo none)"
        '');
        hd-tasks = unit (out "tasks" // { TasksMax = 20; }) (sh "hd-tasks" ''
          ${cgroup}
          echo "pids: $(cat $cg/pids.max)"
          ${p} forks 200
        '');
        hd-tasks-free = unit (out "tasks-free" // { }) (sh "hd-tasks-free" ''
          ${p} forks 60
        '');

        # /proc: the processes of others are not seen, and only they
        hd-proc = unit (
          out "proc"
          // {
            User = "nobody";
            ProtectProc = "invisible";
            ProcSubset = "pid";
          }
        ) (sh "hd-proc" ''
          echo "init: $(test -d /proc/1 && echo yes || echo no)"
          echo "meminfo: $(test -e /proc/meminfo && echo yes || echo no)"
          echo "self: $(test -r /proc/self/status && echo yes || echo no)"
          echo "visible: $(ls /proc | grep -c '^[0-9]')"
        '');
        hd-proc-free = unit (out "proc-free" // { User = "nobody"; }) (sh "hd-proc-free" ''
          echo "init: $(test -d /proc/1 && echo yes || echo no)"
          echo "meminfo: $(test -e /proc/meminfo && echo yes || echo no)"
        '');

        # asks for what is not done: the build says so
        hd-warn = unit { } (sh "hd-warn" "true") // {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = sh "hd-warn" "true";
            IPAddressDeny = "any";
            DevicePolicy = "closed";
            PrivateUsers = true;
            # (nothing: not warned about)
            RemoveIPC = false;
            DeviceAllow = [ ];
          };
        };
      };

      systemd.user.services.hd-warn-user = {
        serviceConfig = {
          ExecStart = sh "hd-warn-user" "true";
          MemoryMax = "1G";
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      print("init:", ${builtins.toJSON nodes.machine.nixithos.init})

      def verdicts(name):
          lines = machine.succeed(f"cat /run/hd-{name}.out").strip().splitlines()
          print(name, lines)
          d = {}
          for l in lines:
              if ": " in l:
                  k, v = l.split(": ", 1)
                  d.setdefault(k, v)
          return d

      def wait_done(*names):
          for n in names:
              machine.wait_for_unit(f"hd-{n}.service")

      wait_done("kill", "errno", "errno-default", "groups", "allow", "plus", "nnp-user", "nnp-root", "arch", "rooted")

      with subtest("SystemCallFilter kills, or fails with an error"):
          v = verdicts("kill")
          assert v["before"] == "ok", v
          # (the shell reports the death of its child; the service goes on)
          assert v["rc"] == "159", v
          assert v["sys reboot"] == "errno=22", v
          v = verdicts("errno")
          assert v["sys getpriority"] == "errno=1", v      # EPERM
          assert v["sys chroot"] == "errno=13", v            # EACCES
          v = verdicts("errno-default")
          assert v["sys getpriority"] == "errno=13", v

      with subtest("system call groups"):
          v = verdicts("groups")
          assert v["shell"] == "ok", v
          assert v["sys getpriority"] == "ok", v
          assert v["forks 3"] == "3", v
          # @privileged: chroot(2) kills
          assert v["rc"] == "159", v
          assert "sys chroot" not in v, v
          v = verdicts("allow")
          assert v["sys getpriority"] == "ok", v
          # reboot(2) is not in @system-service
          assert v["rc"] == "159", v
          assert "sys reboot" not in v, v
          assert verdicts("arch")["ran"] == "ok"

      with subtest("a command with + is not restricted"):
          assert verdicts("plus")["rc"] == "159"
          assert machine.succeed("cat /run/hd-plus-pre.out").strip() == "sys getpriority: ok"

      with subtest("no_new_privs comes with a filter, for a user"):
          assert verdicts("nnp-user")["nnp"] == "1"
          assert verdicts("nnp-root")["nnp"] == "0"

      with subtest("a unit with a root directory of its own gets the filter too"):
          v = verdicts("rooted")
          assert int(v["uid"]) > 0, v
          assert v["rc"] == "159", v
          assert v["mmap-rwx"] != "ok", v

      wait_done("af-unix", "af-deny", "af-free", "mdwe", "mdwe-free", "lock", "lock-free", "rt", "rt-free")
      wait_done("ns-all", "ns-some", "ns-free", "suid", "suid-dynamic")

      with subtest("RestrictAddressFamilies"):
          v = verdicts("af-unix")
          assert v["socket unix"] == "ok", v
          assert v["socket inet"] == "errno=97" and v["socket netlink"] == "errno=97", v   # EAFNOSUPPORT
          v = verdicts("af-deny")
          assert v["socket unix"] == "ok" and v["socket netlink"] == "ok", v
          assert v["socket inet"] == "errno=97", v
          v = verdicts("af-free")
          assert v["socket inet"] == "ok" and v["socket netlink"] == "ok", v

      with subtest("MemoryDenyWriteExecute"):
          v = verdicts("mdwe")
          assert v["mmap-rwx"] != "ok" and v["mprotect-x"] != "ok", v
          v = verdicts("mdwe-free")
          assert v["mmap-rwx"] == "ok" and v["mprotect-x"] == "ok", v

      with subtest("LockPersonality"):
          assert verdicts("lock")["personality"] == "errno=1"
          assert verdicts("lock-free")["personality"] == "ok"

      with subtest("RestrictRealtime"):
          assert verdicts("rt")["sched-fifo"] == "errno=1"
          assert verdicts("rt-free")["sched-fifo"] == "ok"

      with subtest("RestrictNamespaces"):
          v = verdicts("ns-all")
          assert v["unshare uts"] == "errno=1" and v["unshare net"] == "errno=1", v
          v = verdicts("ns-some")
          assert v["unshare uts"] == "ok" and v["unshare net"] == "errno=1", v
          v = verdicts("ns-free")
          assert v["unshare uts"] == "ok" and v["unshare net"] == "ok", v

      with subtest("RestrictSUIDSGID"):
          v = verdicts("suid")
          assert v["chmod 4755"] == "errno=1" and v["chmod 2755"] == "errno=1", v
          assert v["chmod 0755"] == "ok", v
          # DynamicUser= implies it
          assert verdicts("suid-dynamic")["chmod 4755"] == "errno=1"

      wait_done("mem", "cpu", "tasks", "tasks-free", "proc", "proc-free")

      with subtest("MemoryMax, MemoryHigh, MemorySwapMax"):
          v = verdicts("mem")
          assert v["cgroup"].startswith("/sys/fs/cgroup/"), v
          assert v["max"] == str(64 << 20) and v["high"] == str(48 << 20) and v["swap"] == "0", v
          assert v["alloc 8"] == "ok", v
          # the out-of-memory killer took the process that wanted 400 MB
          assert v["rc"] == "137", v
          assert "alloc 400" not in v, v
          assert int(v["oom_kill"]) >= 1, v

      with subtest("CPUQuota, CPUWeight, IOWeight"):
          v = verdicts("cpu")
          assert v["cpumax"] == "50000 100000", v
          assert v["weight"] == "200", v
          # (io.weight is there with a scheduler that has weights)
          assert v["io"] == "none" or "300" in v["io"], v

      with subtest("TasksMax"):
          v = verdicts("tasks")
          assert v["pids"] == "20", v
          made = int(v["forks 200"])
          assert 1 <= made <= 20, v
          assert int(verdicts("tasks-free")["forks 60"]) == 60

      with subtest("ProtectProc, ProcSubset"):
          v = verdicts("proc")
          assert v["init"] == "no" and v["meminfo"] == "no" and v["self"] == "yes", v
          assert int(v["visible"]) <= 8, v
          v = verdicts("proc-free")
          assert v["init"] == "yes" and v["meminfo"] == "yes", v
          # the host keeps its /proc
          machine.succeed("test -e /proc/meminfo && test -d /proc/1")

      with subtest("the build warns about what is asked for and not done"):
          warnings = ${builtins.toJSON nodes.machine.warnings}
          text = "\n".join(warnings)
          line = [l for l in text.splitlines() if l.strip().startswith("hd-warn:")]
          assert len(line) == 1, text
          print(line[0])
          for opt in ("PrivateUsers", "IPAddressDeny", "DevicePolicy"):
              assert opt in line[0], line[0]
          # off, or empty, asks for nothing
          assert "RemoveIPC" not in line[0] and "DeviceAllow" not in line[0], line[0]
          # a user's service has no control group to limit
          assert "user hd-warn-user: MemoryMax" in text, text
          # what is done is not warned about
          assert "hd-kill" not in text and "hd-mem:" not in text, text
    '';
}
