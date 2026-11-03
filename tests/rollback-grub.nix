# Boot assessment with GRUB (BIOS): grubenv holds the generation on trial, the
# one to go back to and the tries left; a piece of grub.cfg counts them down
# before each boot and picks the entry.
{
  name = "rollback-grub";

  nodes.machine =
    { ... }:
    {
      imports = [ ./configs/rollback-node.nix ];
    };

  testScript =
    { nodes, pkgs, ... }:
    ''
      init = "${nodes.machine.nixithos.init}"
      editenv = "${pkgs.grub2}/bin/grub-editenv /boot/grub/grubenv"
    ''
    + builtins.readFile ./configs/rollback-common.py
    + ''
      def env():
          return dict(
              line.split("=", 1)
              for line in machine.succeed(editenv + " list").splitlines()
              if "=" in line
          )

      machine.start(allow_reboot=True)
      assert boot_ended() == "good", "the first boot is a plain one"
      gen1 = booted()
      base = gen1

      with subtest("nothing is on trial at first"):
          assert "On trial:   nothing" in assess("status")
          assert "nixith_trial" not in env(), env()

      with subtest("a generation that resets the machine: three tries, then back"):
          top2, out = new_generation("reset")
          assert "is on trial" in out, out
          e = env()
          print(e)
          assert e["nixith_tries"] == "3" and e["nixith_trial"].startswith("nixith-"), e
          assert e["nixith_good"].startswith("nixith-all>nixith-"), e
          cfg = machine.succeed("cat /boot/grub/grub.cfg")
          assert "--id nixith-all" in cfg and ("--id " + e["nixith_trial"]) in cfg, cfg

          assert reboot() == "rolled-back"
          assert booted() == gen1
          # (it was tried three times, and the one that did not use up the last
          # is the one that went back)
          assert env()["nixith_tries"] == "0", env()
          out = assess("status")
          print(out)
          assert "generation 2 did not boot" in out, out
          assert profile() == "system-1-link", profile()

      with subtest("it stays given up on"):
          assert reboot() == "good"
          assert booted() == gen1

      with subtest("a generation that boots is the default for good"):
          top3, out = new_generation("fine")
          assert env()["nixith_tries"] == "3", env()
          assert reboot() == "good-trial"
          assert booted() == top3
          assert "nixith_trial" not in env(), env()
          machine.succeed("grep -qx fine /etc/rollback-marker")
          assert "On trial:   nothing" in assess("status")

      with subtest("a generation whose boot has a unit fail is not good either"):
          top4, out = new_generation("unit")
          for left in (2, 1, 0):
              assert reboot() == "not-good"
              assert booted() == top4
              assert env()["nixith_tries"] == str(left), env()
          assert reboot() == "rolled-back"
          assert booted() == top3
          out = assess("status")
          print(out)
          assert "generation 4 did not boot" in out, out
          assert profile() == "system-3-link", profile()

      with subtest("the next install is back to a plain menu"):
          machine.succeed("/run/current-system/bin/switch-to-configuration boot 2>&1")
          assert "nixith_trial" not in env(), env()
          assert reboot() == "good"
          assert booted() == top3

      machine.shutdown()
    '';
}
