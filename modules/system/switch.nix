# switch-to-configuration: what `nixos-rebuild switch` runs to move a live
# system to a new configuration.  Options are upstream's
# (system/activation/switchable-system.nix, imported options-only); the
# program is pkgs/switch-to-configuration, which talks to s6-rc.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  switch = pkgs.nixithos.switch-to-configuration.override {
    nixithos = pkgs.nixithos // {
      unitRuntime = config.system.build.unitRuntime;
    };
  };
in

{
  config = lib.mkIf config.system.switch.enable {
    system = {
      activatableSystemBuilderCommands = ''
        (
          source ${pkgs.buildPackages.makeWrapper}/nix-support/setup-hook

          mkdir -p $out/bin
          makeWrapper ${lib.getExe switch} $out/bin/switch-to-configuration \
            --set OUT $out \
            --set TOPLEVEL ''${!toplevelVar} \
            --set DISTRO_ID ${lib.escapeShellArg config.system.nixos.distroId} \
            --set INSTALL_BOOTLOADER ${lib.escapeShellArg config.system.build.installBootLoader} \
            --set PRE_SWITCH_CHECK ${lib.escapeShellArg config.system.preSwitchChecksScript} \
            ${
              lib.optionalString (
                config.i18n.glibcLocales != null
              ) "--set LOCALE_ARCHIVE ${config.i18n.glibcLocales}/lib/locale/locale-archive"
            }
        )
      '';

      systemBuilderCommands = ''
        ln -s ${config.system.build.inhibitSwitch} $out/switch-inhibitors
      '';

      build.inhibitSwitch = pkgs.writers.writeJSON "switch-inhibitors" config.system.switch.inhibitors;

      preSwitchChecks.switchInhibitors =
        let
          jq = lib.getExe pkgs.jq;
          empty = pkgs.writeText "empty-inhibitors" "{}";
        in
        ''
          incoming="''${1-}"
          action="''${2-}"

          case "$action" in
            boot|dry-activate)
              echo "Not checking switch inhibitors (action = $action)"
              exit
              ;;
          esac

          echo -n "Checking switch inhibitors..."

          current_inhibitors="/run/current-system/switch-inhibitors"
          if [ ! -f "$current_inhibitors" ]; then
            current_inhibitors="${empty}"
          fi

          new_inhibitors="$incoming/switch-inhibitors"
          if [ ! -f "$new_inhibitors" ]; then
            new_inhibitors="${empty}"
          fi

          diff="$(
            ${jq} \
              --raw-output \
              --null-input \
              --rawfile current "$current_inhibitors" \
              --rawfile newgen "$new_inhibitors" \
            '
              ($current | fromjson) as $old |
              ($newgen | fromjson) as $new |
              $old |
              to_entries |
              map(
                select(.key | in ($new)) |
                select(.value != $new.[.key]) |
                [ .key, ":", .value, "->", $new.[.key] ] | join(" ")
              ) |
              join("\n")
            ' \
          )"

          if [ -n "$diff" ]; then
            echo
            echo "There are changes to critical components of the system:"
            echo
            echo "$diff"
            echo
            echo "Switching into this system is not recommended."
            echo "You probably want to run 'nixos-rebuild boot' and reboot your system instead."
            echo
            echo "If you really want to switch into this configuration directly, then"
            echo "you can set NIXOS_NO_CHECK=1 to ignore pre-switch checks."
            echo
            echo "WARNING: doing so might cause the switch to fail or your system to become unstable."
            echo
            exit 1
          else
            echo " done"
          fi
        '';
    };

    security =
      let
        extraConfig = ''
          Defaults env_keep+=NIXOS_NO_CHECK
        '';
      in
      {
        sudo = { inherit extraConfig; };
        sudo-rs = { inherit extraConfig; };
      };
  };
}
