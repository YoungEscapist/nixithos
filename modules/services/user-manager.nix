# The service managers of users (`systemd.user.*`): one s6 supervision tree
# per logged-in user, started when their first session opens and stopped
# after the last one closes.  See ../../pkgs/user-manager.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.s6.userManager;
  elogind = config.services.elogind;
  inherit (pkgs.nixithos) userManager;
in

{
  options = {
    s6.userManager.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether sessions get a service manager of their own for the units of
        `systemd.user.*`.  It is started by a PAM module in every service
        that opens sessions.
      '';
    };

    # Added to every PAM service: the hook that starts and stops the manager.
    security.pam.services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            # (services that start no sessions have no such rules, and some,
            # like `other`, have hand-written ones: so the conditions are on
            # whole sets of rules, never on a single field of one)
            config.rules.session = lib.mkMerge [
              # pam_systemd only exists when there is a login manager to put
              # in its place; without one the rule would fail at every login.
              (lib.mkIf (config.startSession && !elogind.enable) {
                systemd.enable = lib.mkForce false;
              })

              (lib.mkIf (cfg.enable && config.startSession) {
                s6-user-manager = {
                  enable = true;
                  control = "optional";
                  modulePath = "${pkgs.linux-pam}/lib/security/pam_exec.so";
                  args = [
                    "quiet"
                    "${userManager}/bin/user-manager"
                    "hook"
                  ];
                  # after the module that makes /run/user/UID
                  order = config.rules.session.systemd.order + 10;
                };
                # XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS, as pam_systemd
                # sets them, once the hook has the user's services up
                s6-session-env = {
                  enable = true;
                  control = "optional";
                  modulePath = "${pkgs.nixithos.unitTools}/lib/security/pam_s6_env.so";
                  order = config.rules.session.systemd.order + 11;
                };
              })
            ];
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    # The scan directory the per-user supervisors are created in.
    s6.rc.services.user-managers = {
      type = "longrun";
      wantedByDefault = true;
      run = ''
        #!${pkgs.runtimeShell}
        exec 2>&1
        exec ${userManager}/bin/user-manager supervise
      '';
      files."timeout-down".text = "60000\n";
    };

    # Users that are to have a manager without being logged in.
    environment.systemPackages = [ userManager ];

    # `users.users.<name>.linger` is applied by a unit that waits for logind.
    # With no login manager (services.elogind) there is none to wait for, and
    # the loginctl of the shim writes the same files that the managers read.
    systemd.services.linger-users = lib.mkIf (config.users.manageLingering && !elogind.enable) {
      after = lib.mkForce [ ];
      requires = lib.mkForce [ ];
    };
  };
}
