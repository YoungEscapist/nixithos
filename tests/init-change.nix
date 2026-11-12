# The init system of an installed system is changed in its configuration
# (`nixithos.init`), like anything else: `nixith boot` builds the system with
# the other one and makes it the boot default, and after a reboot that one
# runs the machine.  Here an installation on s6 goes to dinit, runit, OpenRC
# and Finit in turn and back to s6, booting through its boot loader each time;
# the systems are specialisations of the first, as in the boot assessment
# tests.  A `switch` to another init system applies the rest of the
# configuration and says that the init system itself takes a reboot.
{
  name = "init-change";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      s6.systemdPackages = "replace";
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.systemd-boot.enable = true;
      boot.loader.timeout = 0;

      specialisation = lib.genAttrs [ "dinit" "runit" "openrc" "finit" ] (init: {
        configuration = {
          nixithos.init = lib.mkForce init;
          environment.etc."init-marker".text = "${init}\n";
        };
      });
    };

  testScript =
    { nodes, ... }:
    ''
      assert "${nodes.machine.nixithos.init}" == "s6", "the test starts from s6"

      PID1 = {"s6": "s6-svscan", "dinit": "dinit", "runit": "runit", "openrc": "openrc-init", "finit": "finit"}

      def running(init):
          machine.wait_for_unit("multi-user.target")
          machine.succeed(f"grep -q {PID1[init]} /proc/1/cmdline")
          # (what the booted system says its init is: "s6-rc 262", "dinit 262")
          name = "s6-rc" if init == "s6" else init
          booted = machine.succeed("cat /run/booted-system/init-interface-version")
          assert booted.split()[0] == name, booted
          failed = machine.succeed("systemctl list-units --failed --no-legend").strip()
          assert failed == "", f"{init}: failed units:\n{failed}"

      def generation(top, action):
          machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {top}")
          out = machine.succeed(f"{top}/bin/switch-to-configuration {action} 2>&1")
          print(out)
          return out

      machine.start(allow_reboot=True)
      running("s6")
      base = machine.succeed("readlink -f /run/booted-system").strip()

      for init in ("dinit", "runit", "openrc", "finit"):
          with subtest(f"{init}: built from the configuration, the boot default, runs after a reboot"):
              top = machine.succeed(f"readlink -f {base}/specialisation/{init}").strip()
              generation(top, "boot")
              # (nothing of the running system has changed)
              machine.fail("test -e /etc/init-marker && grep -qx %s /etc/init-marker" % init)
              machine.reboot()
              running(init)
              machine.succeed(f"grep -qx {init} /etc/init-marker")
              assert machine.succeed("readlink -f /run/booted-system").strip() == top

      with subtest("switch to another init system: the configuration now, the init system at the next boot"):
          out = generation(base, "switch")
          assert "the new configuration is for s6, and finit runs this machine" in out and "next boot" in out, out
          machine.fail("test -e /etc/init-marker")
          machine.succeed("grep -q finit /proc/1/cmdline")
          machine.reboot()
          running("s6")
          machine.shutdown()
    '';
}
