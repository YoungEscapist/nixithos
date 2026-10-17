# What unit files promise, checked one setting at a time: each `t-…` unit
# below exercises one piece of systemd.service(5)/systemd.exec(5), and the
# test script looks at what actually happened.
{
  name = "units";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      sleep = "${pkgs.coreutils}/bin/sleep infinity";
      sh = name: text: "${pkgs.writeShellScript name text}";
    in
    {
      imports = [ ./configs/minimal-node.nix ];

      environment.etc."t-env-file".text = ''
        # a comment
        FILEVAR=from file
        QUOTED="with spaces"
      '';
      environment.etc."t-secret".text = "s3cret";

      environment.systemPackages = [ pkgs.socat ];

      systemd.services = {
        t-simple = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = sleep;
        };

        t-env = {
          wantedBy = [ "multi-user.target" ];
          environment = {
            FOO = "bar baz";
            EMPTY = "";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            EnvironmentFile = "/etc/t-env-file";
            # $FOO as a word of its own is split, ''${FOO} is not
            ExecStart = "${sh "t-env" ''
              printf '%s|' "$@" > /run/t-env.args
              echo "FOO=$FOO FILEVAR=$FILEVAR QUOTED=$QUOTED HOME=''${HOME-unset}" > /run/t-env.out
            ''} $FOO \${FOO} literal\\x20space";
          };
        };

        t-user = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            User = "nobody";
            Group = "nogroup";
            RuntimeDirectory = "t-user";
            StateDirectory = "t-user";
            UMask = "0027";
            ExecStart = sh "t-user" ''
              id -un > "$RUNTIME_DIRECTORY/user"
              id -gn > "$RUNTIME_DIRECTORY/group"
              echo "$HOME" > "$RUNTIME_DIRECTORY/home"
              touch "$STATE_DIRECTORY/ok"
              exec ${sleep}
            '';
          };
        };

        t-hooks = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStartPre = [
              "${pkgs.coreutils}/bin/touch /run/t-hooks.pre"
              "-${pkgs.coreutils}/bin/false"
            ];
            ExecStart = sleep;
            ExecStartPost = sh "t-hooks-post" ''echo "$MAINPID" > /run/t-hooks.post'';
            ExecReload = "${pkgs.coreutils}/bin/touch /run/t-hooks.reload";
            ExecStop = sh "t-hooks-stop" ''echo "$MAINPID" > /run/t-hooks.stop'';
            ExecStopPost = sh "t-hooks-stop-post" ''echo "$SERVICE_RESULT" > /run/t-hooks.stoppost'';
          };
        };

        t-restart = {
          wantedBy = [ "multi-user.target" ];
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Restart = "always";
            RestartSec = 0;
            ExecStart = sh "t-restart" ''
              echo run >> /run/t-restart.count
              sleep 1
              exit 3
            '';
          };
        };

        t-no-restart = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = sh "t-no-restart" ''
            echo run >> /run/t-no-restart.count
            exit 1
          '';
        };

        t-limit = {
          wantedBy = [ "multi-user.target" ];
          unitConfig = {
            StartLimitIntervalSec = 60;
            StartLimitBurst = 3;
          };
          serviceConfig = {
            Restart = "on-failure";
            RestartSec = 0;
            ExecStart = sh "t-limit" ''
              echo run >> /run/t-limit.count
              exit 1
            '';
          };
        };

        t-notify = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "notify";
            NotifyAccess = "all";
            ExecStart = sh "t-notify" ''
              sleep 2
              touch /run/t-notify.ready
              systemd-notify --ready
              exec ${sleep}
            '';
          };
        };
        t-after-notify = {
          wantedBy = [ "multi-user.target" ];
          requires = [ "t-notify.service" ];
          after = [ "t-notify.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = sh "t-after-notify" ''
              if [ -e /run/t-notify.ready ]; then echo yes; else echo no; fi > /run/t-after-notify.out
            '';
          };
        };

        t-forking = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "forking";
            PIDFile = "/run/t-forking.pid";
            ExecStart = sh "t-forking" ''
              ${pkgs.util-linux}/bin/setsid ${sleep} &
              echo $! > /run/t-forking.pid
            '';
          };
        };

        t-cond = {
          wantedBy = [ "multi-user.target" ];
          unitConfig.ConditionPathExists = "/does/not/exist";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/touch /run/t-cond.ran";
          };
        };

        # ordering: b must see what a wrote
        t-order-a = {
          wantedBy = [ "multi-user.target" ];
          before = [ "t-order-b.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = sh "t-order-a" ''
              sleep 2
              touch /run/t-order-a.done
            '';
          };
        };
        t-order-b = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = sh "t-order-b" ''
              if [ -e /run/t-order-a.done ]; then echo yes; else echo no; fi > /run/t-order-b.out
            '';
          };
        };

        # a wanted unit that fails does not take the units after it down…
        t-soft-fail = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/false";
          };
        };
        t-after-soft-fail = {
          wantedBy = [ "multi-user.target" ];
          wants = [ "t-soft-fail.service" ];
          after = [ "t-soft-fail.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/touch /run/t-after-soft-fail.ran";
          };
        };
        # …a required one does.
        t-hard-fail = {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/false";
          };
        };
        t-needs-hard-fail = {
          wantedBy = [ "multi-user.target" ];
          requires = [ "t-hard-fail.service" ];
          after = [ "t-hard-fail.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/touch /run/t-needs-hard-fail.ran";
          };
        };

        # a failing longrun must not hold back what is merely ordered after it
        t-broken-daemon = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/false";
        };
        t-after-broken-daemon = {
          wantedBy = [ "multi-user.target" ];
          after = [ "t-broken-daemon.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/touch /run/t-after-broken-daemon.ran";
          };
        };

        t-echo = {
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat ACCEPT-FD:3,fork EXEC:${pkgs.coreutils}/bin/cat";
        };

        # OnFailure= and OnSuccess=
        t-onfail = {
          wantedBy = [ "multi-user.target" ];
          onFailure = [ "t-onfail-handler.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/false";
          };
        };
        t-onsuccess = {
          wantedBy = [ "multi-user.target" ];
          onSuccess = [ "t-onsuccess-handler.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        t-onfail-handler.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/touch /run/t-onfail.handled";
        };
        t-onsuccess-handler.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/touch /run/t-onsuccess.handled";
        };

        # .path: started by a file appearing, which it then removes
        t-path-job = {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = sh "t-path-job" ''
              echo ran >> /run/t-path.count
              rm -f /run/t-path.trigger
            '';
          };
        };

        # Accept=yes: one instance per connection, the connection as stdin/out
        "t-accept@" = {
          serviceConfig = {
            StandardInput = "socket";
            ExecStart = sh "t-accept" ''
              echo "from $REMOTE_ADDR instance $UNIT_ACCEPT_INSTANCE"
              exec ${pkgs.coreutils}/bin/cat
            '';
          };
        };
        # ... or on descriptor 3, as for any socket-activated program
        "t-accept-fd@" = {
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat FD:3 EXEC:${pkgs.coreutils}/bin/cat";
        };

        # what a timer points at that is not a oneshot (no Type= is "simple"):
        # a batch job that comes and goes, and a daemon that stays
        t-job-simple = {
          serviceConfig.ExecStart = sh "t-job-simple" "echo tick >> /run/t-job-simple.count";
        };
        t-job-daemon = {
          serviceConfig.ExecStart = sh "t-job-daemon" ''
            echo start >> /run/t-job-daemon.count
            exec ${sleep}
          '';
        };

        t-job = {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = sh "t-job" "echo tick >> /run/t-job.count";
          };
        };

        "t-template@" = {
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/touch /run/t-template.%i";
          };
        };

        t-caps = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "nobody";
            AmbientCapabilities = "CAP_NET_BIND_SERVICE";
            LimitNOFILE = 4321;
            WorkingDirectory = "/tmp";
            NoNewPrivileges = true;
            StandardOutput = "file:/run/t-caps.out";
            ExecStart = sh "t-caps" ''
              grep -E '^(CapAmb|NoNewPrivs)' /proc/self/status
              echo "nofile=$(ulimit -n)"
              echo "cwd=$PWD"
            '';
          };
        };

        t-creds = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "nobody";
            LoadCredential = "secret:/etc/t-secret";
            ExecStart = sh "t-creds" ''cat "$CREDENTIALS_DIRECTORY/secret" > /tmp/t-creds.out'';
          };
        };

        # a unit that asks for its own restart: from its ExecStartPost= (as
        # influxdb2 does) the restart comes when the start is done; from the
        # running process it is carried out at once.  Once each, and not
        # after RestartSec=.
        t-self-start = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            RestartSec = 600;
            ExecStartPre = sh "t-self-start-pre" "echo x >> /run/t-self-start.starts";
            ExecStart = sleep;
            ExecStartPost = "+${sh "t-self-start-post" ''
              if [ ! -e /run/t-self-start.done ]; then
                touch /run/t-self-start.done
                /run/current-system/systemd/bin/systemctl restart t-self-start
              fi
            ''}";
          };
        };
        t-self-run = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            RestartSec = 600;
            ExecStart = sh "t-self-run" ''
              echo x >> /run/t-self-run.starts
              if [ ! -e /run/t-self-run.done ]; then
                touch /run/t-self-run.done
                /run/current-system/systemd/bin/systemctl restart t-self-run
              fi
              exec ${sleep}
            '';
          };
        };

        # `systemctl start --wait`: returns when the service has finished
        t-wait-ok = {
          serviceConfig.ExecStart = sh "t-wait-ok" "sleep 3; echo done > /run/t-wait-ok.out";
        };
        t-wait-fail = {
          serviceConfig.ExecStart = sh "t-wait-fail" "sleep 1; exit 7";
        };

        # everything a service started goes away with it
        t-children = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = sh "t-children" ''
            ${pkgs.util-linux}/bin/setsid ${pkgs.coreutils}/bin/sleep 987654 &
            exec ${sleep}
          '';
        };
      };

      systemd.sockets.t-echo = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "/run/t-echo.sock" ];
        socketConfig.SocketMode = "0600";
      };

      systemd.paths.t-path = {
        wantedBy = [ "paths.target" ];
        pathConfig = {
          PathExists = "/run/t-path.trigger";
          Unit = "t-path-job.service";
        };
      };

      systemd.sockets.t-accept = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "127.0.0.1:7007" ];
        socketConfig.Accept = true;
      };
      systemd.sockets.t-accept-fd = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "/run/t-accept-fd.sock" ];
        socketConfig.Accept = true;
      };

      systemd.timers.t-job-simple = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "3s";
          OnUnitActiveSec = "3s";
        };
      };
      systemd.timers.t-job-daemon = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "3s";
          OnUnitActiveSec = "3s";
        };
      };

      systemd.timers.t-job = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "3s";
          OnUnitActiveSec = "3s";
        };
      };

      systemd.targets.multi-user.wants = [ "t-template@one.service" ];
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def read(path):
        return machine.succeed(f"cat {path}").strip()

    with subtest("environment"):
        assert read("/run/t-env.out") == "FOO=bar baz FILEVAR=from file QUOTED=with spaces HOME=unset", read("/run/t-env.out")
        assert read("/run/t-env.args") == "bar|baz|bar baz|literal space|", read("/run/t-env.args")

    with subtest("user, directories, umask"):
        assert read("/run/t-user/user") == "nobody"
        assert read("/run/t-user/group") == "nogroup"
        machine.succeed("test -e /var/lib/t-user/ok")
        assert machine.succeed("stat -c %U:%a /var/lib/t-user/ok").strip() == "nobody:640"
        assert machine.succeed("stat -c %U /run/t-user").strip() == "nobody"

    with subtest("ExecStartPre/Post, reload, ExecStop/StopPost"):
        machine.succeed("test -e /run/t-hooks.pre")
        pid = machine.succeed("systemctl show -p MainPID --value t-hooks").strip()
        assert read("/run/t-hooks.post") == pid, (read("/run/t-hooks.post"), pid)
        machine.succeed("systemctl reload t-hooks && test -e /run/t-hooks.reload")
        machine.succeed("systemctl stop t-hooks")
        assert read("/run/t-hooks.stop") == pid
        assert read("/run/t-hooks.stoppost") == "success", read("/run/t-hooks.stoppost")
        machine.fail("systemctl is-active t-hooks")
        machine.succeed("systemctl start t-hooks && systemctl is-active t-hooks")
        # the native way stops it too, hooks included
        machine.succeed("rm /run/t-hooks.stop && s6-rc -d change t-hooks && test -e /run/t-hooks.stop")
        machine.succeed("s6-rc -u change t-hooks-hooks && systemctl is-active t-hooks")

    with subtest("restart policy"):
        machine.wait_until_succeeds("test $(wc -l < /run/t-restart.count) -ge 3")
        machine.sleep(3)
        assert read("/run/t-no-restart.count") == "run"
        assert machine.succeed("systemctl is-failed t-no-restart || true").strip() == "failed"
        machine.wait_until_succeeds("systemctl is-failed t-limit")
        assert read("/run/t-limit.count").count("run") == 3, read("/run/t-limit.count")

    with subtest("readiness and ordering"):
        assert read("/run/t-after-notify.out") == "yes"
        assert read("/run/t-order-b.out") == "yes"
        machine.succeed("systemctl is-active t-forking")
        assert machine.succeed("systemctl show -p MainPID --value t-forking").strip() == read("/run/t-forking.pid")
        machine.succeed("systemctl stop t-forking")
        machine.fail("kill -0 $(cat /run/t-forking.pid)")

    with subtest("conditions"):
        machine.fail("test -e /run/t-cond.ran")
        machine.fail("systemctl is-failed t-cond")

    with subtest("failures propagate like systemd's"):
        machine.succeed("test -e /run/t-after-soft-fail.ran")
        machine.succeed("systemctl is-failed t-soft-fail")
        machine.fail("test -e /run/t-needs-hard-fail.ran")
        machine.succeed("test -e /run/t-after-broken-daemon.ran")

    with subtest("OnFailure= and OnSuccess="):
        machine.wait_until_succeeds("test -e /run/t-onfail.handled", timeout=30)
        machine.wait_until_succeeds("test -e /run/t-onsuccess.handled", timeout=30)

    with subtest("socket units"):
        assert machine.succeed("stat -c %a /run/t-echo.sock").strip() == "600"
        assert machine.succeed("echo hello | socat -t 2 - UNIX-CONNECT:/run/t-echo.sock").strip() == "hello"
        # the socket survives a restart of its service
        machine.succeed("systemctl restart t-echo")
        assert machine.succeed("echo again | socat -t 2 - UNIX-CONNECT:/run/t-echo.sock").strip() == "again"
        # stopped, it is started again by the next connection
        machine.succeed("systemctl stop t-echo")
        machine.fail("systemctl is-active t-echo")
        assert machine.succeed("echo back | socat -t 5 - UNIX-CONNECT:/run/t-echo.sock").strip() == "back"
        machine.wait_until_succeeds("systemctl is-active t-echo", timeout=30)

    with subtest("Accept=yes sockets"):
        out = machine.succeed("echo hello | socat -t 3 - TCP:127.0.0.1:7007")
        assert out.startswith("from 127.0.0.1 instance 0-127.0.0.1:7007-127.0.0.1:"), out
        assert out.splitlines()[1] == "hello", out
        # a second connection is an instance of its own, and the first one
        # does not have to be over
        out = machine.succeed("echo again | socat -t 3 - TCP:127.0.0.1:7007")
        assert out.startswith("from 127.0.0.1 instance 1-"), out
        # (descriptor 3)
        out = machine.succeed("echo abc | socat -t 3 - UNIX-CONNECT:/run/t-accept-fd.sock").strip()
        assert out == "abc", out
        machine.succeed("systemctl is-active t-accept.socket")

    with subtest("path units"):
        machine.succeed("systemctl is-active t-path.path")
        machine.fail("test -e /run/t-path.count")
        machine.succeed("touch /run/t-path.trigger")
        machine.wait_until_succeeds("test -s /run/t-path.count", timeout=30)
        machine.wait_until_fails("test -e /run/t-path.trigger", timeout=30)

    with subtest("timers"):
        machine.wait_until_succeeds("test $(wc -l < /run/t-job.count) -ge 2", timeout=30)
        # a timer's target that is not a oneshot: a batch job runs on every
        # trigger, a daemon is started once and stays
        machine.wait_until_succeeds("test $(wc -l < /run/t-job-simple.count) -ge 2", timeout=30)
        machine.wait_until_succeeds("test -e /run/t-job-daemon.count", timeout=30)
        machine.sleep(7)
        assert read("/run/t-job-daemon.count") == "start", read("/run/t-job-daemon.count")
        machine.succeed("systemctl is-active t-job-daemon.service")
        print(machine.succeed("systemctl list-timers"))

    with subtest("start --wait"):
        machine.succeed("systemctl start --wait t-wait-ok && test -e /run/t-wait-ok.out")
        machine.fail("systemctl start --wait t-wait-fail")

    with subtest("templates"):
        machine.succeed("test -e /run/t-template.one")

    with subtest("a unit restarting itself"):
        for unit in ("t-self-start", "t-self-run"):
            machine.wait_until_succeeds(f"test $(wc -l < /run/{unit}.starts) -ge 2", timeout=60)
            machine.wait_for_unit(f"{unit}.service")
            machine.sleep(1)
            n = machine.succeed(f"wc -l < /run/{unit}.starts").strip()
            assert n == "2", (unit, n)

    with subtest("capabilities, limits, working directory"):
        out = read("/run/t-caps.out")
        assert "CapAmb:\t0000000000000400" in out, out
        assert "NoNewPrivs:\t1" in out, out
        assert "nofile=4321" in out, out
        assert "cwd=/tmp" in out, out

    with subtest("credentials"):
        assert read("/tmp/t-creds.out") == "s3cret"

    with subtest("stopping a service stops its children"):
        machine.succeed("pgrep -f 'sleep 987654'")
        machine.succeed("systemctl stop t-children")
        machine.fail("pgrep -f 'sleep 987654'")

    with subtest("logs"):
        machine.succeed("systemctl restart t-simple")
        machine.succeed("journalctl -u t-no-restart | grep -q 'failed'")
        print(machine.succeed("systemctl status t-restart || true"))
  '';
}
