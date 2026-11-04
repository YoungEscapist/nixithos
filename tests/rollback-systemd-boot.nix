# Boot assessment with systemd-boot: a new generation is put on trial with the
# loader's own boot counting (+3 in the name of its entry).  One that resets the
# machine in stage 2, and one whose boot has a unit that fails, are each tried
# three times and then the loader boots the generation that was running; one
# that boots becomes the default for good.
{
  name = "rollback-systemd-boot";

  nodes.machine =
    { ... }:
    {
      imports = [ ./configs/rollback-node.nix ];
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.systemd-boot.enable = true;
    };

  testScript =
    { nodes, ... }:
    ''
      init = "${nodes.machine.nixithos.init}"
    ''
    + builtins.readFile ./configs/rollback-common.py
    + ''
      def entries():
          return machine.succeed("ls /boot/loader/entries").split()

      machine.start(allow_reboot=True)
      assert boot_ended() == "good", "the first boot is a plain one"
      gen1 = booted()
      base = gen1

      with subtest("nothing is on trial at first"):
          out = assess("status")
          print(out)
          assert "On trial:   nothing" in out, out
          assert "nixos-generation-1.conf" in entries(), entries()

      with subtest("a generation that resets the machine: three tries, then back"):
          top2, out = new_generation("reset")
          assert "is on trial" in out, out
          e = entries()
          assert "nixos-generation-2+3.conf" in e and "nixos-generation-2.conf" not in e, e
          machine.succeed("grep -qx 'toplevel=%s' /var/lib/nixith/boot-assessment/trial" % top2)
          assert "On trial:   generation 2" in assess("status")

          assert reboot() == "rolled-back"
          assert booted() == gen1
          e = entries()
          print(e)
          assert "nixos-generation-2+0-3.conf" in e and "nixos-generation-2.conf" not in e, e
          out = assess("status")
          print(out)
          assert "generation 2 did not boot" in out and "generation 1 runs instead" in out, out
          assert profile() == "system-1-link", profile()
          machine.fail("test -e /var/lib/nixith/boot-assessment/trial")

      with subtest("it stays given up on"):
          assert reboot() == "good"
          assert booted() == gen1

      with subtest("what the installer writes again does not bring it back"):
          machine.succeed("/run/current-system/bin/switch-to-configuration boot 2>&1")
          e = entries()
          assert "nixos-generation-2+0-3.conf" in e and "nixos-generation-2.conf" not in e, e
          assert reboot() == "good"
          assert booted() == gen1

      with subtest("a generation that boots is the default for good"):
          top3, out = new_generation("fine")
          assert "nixos-generation-3+3.conf" in entries(), entries()
          assert reboot() == "good-trial"
          assert booted() == top3
          e = entries()
          assert "nixos-generation-3.conf" in e and "nixos-generation-3+3.conf" not in e, e
          machine.succeed("grep -qx fine /etc/rollback-marker")
          assert "On trial:   nothing" in assess("status")
          machine.fail("test -e /var/lib/nixith/boot-assessment/trial")

      with subtest("a generation whose boot has a unit fail is not good either"):
          top4, out = new_generation("unit")
          assert "nixos-generation-4+3.conf" in entries(), entries()
          for left, done in ((2, 1), (1, 2), (0, 3)):
              assert reboot() == "not-good"
              assert booted() == top4
              assert f"nixos-generation-4+{left}-{done}.conf" in entries(), entries()
              machine.succeed("systemctl is-active canary.service || true")
              # (not marked: the entry keeps its count)
              machine.succeed("test -e /var/lib/nixith/boot-assessment/trial")
          assert reboot() == "rolled-back"
          assert booted() == top3
          out = assess("status")
          print(out)
          assert "generation 4 did not boot" in out, out
          assert profile() == "system-3-link", profile()

      with subtest("nixith tells"):
          if machine.execute("command -v nixith")[0] == 0:
              out = machine.succeed("nixith boot-status 2>&1")
              assert "generation 4 did not boot" in out, out
              machine.succeed("nixith boot-status --ack")
              assert "did not boot" not in machine.succeed("nixith boot-status 2>&1")
          else:
              out = machine.succeed("nixith-boot-assess note 2>&1")
              assert "generation 4 did not boot" in out, out

      machine.shutdown()
    '';
}
