# Boot assessment with Limine (UEFI): Limine remembers nothing and counts
# nothing, so the old generation stays its default and the new one is started
# once, through a UEFI boot entry for its kernel that BootNext points at.
{
  name = "rollback-limine";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ./configs/rollback-node.nix ];
      environment.systemPackages = [ pkgs.efibootmgr ];
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.limine.enable = true;
      boot.loader.limine.efiSupport = true;
    };

  testScript =
    { nodes, ... }:
    ''
      init = "${nodes.machine.nixithos.init}"
      efibootmgr = "efibootmgr"
    ''
    + builtins.readFile ./configs/rollback-common.py
    + ''
      def boot_entries():
          return machine.succeed(efibootmgr)

      def default_entry():
          """The system that Limine's default entry starts."""
          return machine.succeed(
              "idx=$(sed -n 's/^default_entry: //p' /boot/limine/limine.conf); "
              "awk -v want=$idx '/^\\/+/ { n++ } n == want && /cmdline:/ { for (i = 2; i <= NF; i++) "
              "if ($i ~ /^init=/) { sub(/^init=/, \"\", $i); sub(/\\/init$/, \"\", $i); print $i } }' /boot/limine/limine.conf"
          ).strip()

      machine.start(allow_reboot=True)
      assert boot_ended() == "good", "the first boot is a plain one"
      gen1 = booted()
      base = gen1
      default1 = default_entry()
      assert default1 == gen1, (default1, gen1)

      with subtest("nothing is on trial at first"):
          assert "On trial:   nothing" in assess("status")
          assert "NixithOS trial" not in boot_entries(), boot_entries()

      with subtest("a generation that resets the machine: tried once, then back"):
          top2, out = new_generation("reset")
          assert "is on trial" in out, out
          b = boot_entries()
          print(b)
          assert "NixithOS trial" in b and "BootNext" in b, b
          # (the default is the generation that runs, not the new one)
          assert default_entry() == gen1, (default_entry(), gen1)

          assert reboot() == "rolled-back"
          assert booted() == gen1
          b = boot_entries()
          assert "NixithOS trial" not in b and "BootNext" not in b, b
          out = assess("status")
          print(out)
          assert "generation 2 did not boot" in out, out
          assert profile() == "system-1-link", profile()

      with subtest("it stays given up on"):
          assert reboot() == "good"
          assert booted() == gen1

      with subtest("a generation that boots is the default for good"):
          top3, out = new_generation("fine")
          assert reboot() == "good-trial"
          assert booted() == top3
          b = boot_entries()
          print(b)
          # (it did boot through the entry that was made for it)
          assert "NixithOS trial" not in b and "BootNext" not in b, b
          machine.succeed("grep -q 'init=%s/init' /proc/cmdline" % top3)
          machine.succeed("grep -qx fine /etc/rollback-marker")
          assert default_entry() == top3, (default_entry(), top3)
          assert "On trial:   nothing" in assess("status")
          # (and Limine itself now starts it)
          assert reboot() == "good"
          assert booted() == top3

      with subtest("a generation whose boot has a unit fail is not good either"):
          top4, out = new_generation("unit")
          assert reboot() == "not-good"
          assert booted() == top4
          assert reboot() == "rolled-back"
          assert booted() == top3
          out = assess("status")
          print(out)
          assert "generation 4 did not boot" in out, out
          assert profile() == "system-3-link", profile()

      machine.shutdown()
    '';
}
