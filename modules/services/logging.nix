# Where log messages go.
#
#   * A service's stdout and stderr are read by an s6-log process of its own,
#     which writes to /var/log/s6/<service>/ (see ../s6/default.nix).
#   * Messages sent with syslog(3) arrive on /dev/log; s6-socklog reads them
#     there, and like any other service it is logged by s6-log.
#   * Kernel messages are followed by a small service of their own.
#   * Whatever has no logger at all (boot progress, the supervision tree
#     itself) is caught by s6-linux-init's catch-all logger, in
#     /run/uncaught-logs.
#
# The syslog service takes the place and the unit name of systemd-journald,
# which is what other units order themselves after.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.s6.logging;
  rsyslogd = config.services.rsyslogd.enable;
  # (what journald would do: send the messages on to the syslog daemon)
  forward = rsyslogd && config.services.journald.forwardToSyslog;

  # `ForwardToConsole=yes` and `TTYPath=` of journald.conf, as set by
  # `services.journald.console` or in `extraConfig` (a test VM sets them to
  # have what its machines log appear on the serial console, where the test
  # driver looks for it): the loggers write what they are given there too.
  consoleTty =
    let
      extra = config.services.journald.extraConfig;
      m = builtins.match "(.*\n)?TTYPath=([^\n]*)(\n.*)?" extra;
    in
    if config.services.journald.console != "" then
      config.services.journald.console
    else if lib.hasInfix "ForwardToConsole=yes" extra && m != null then
      lib.elemAt m 1
    else
      null;
in

{
  options.s6.logging = {
    syslog.enable = lib.mkOption {
      type = lib.types.bool;
      default = !forward;
      defaultText = lib.literalExpression "!(config.services.rsyslogd.enable && config.services.journald.forwardToSyslog)";
      description = ''
        Whether to collect syslog(3) messages from {file}`/dev/log`.  A
        syslog daemon of its own (rsyslogd) takes this over.
      '';
    };

    kernel.enable = lib.mkOption {
      type = lib.types.bool;
      default = !config.boot.isContainer;
      defaultText = lib.literalExpression "!config.boot.isContainer";
      description = "Whether to record kernel messages.";
    };

    echoFailures = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether a service that fails has the tail of its log written to
        the console, as a line of the boot messages.  Where there is no
        way to read the log afterwards (a test VM that gives up), it is
        the only record of why.
      '';
    };
  };

  config = {
    # systemd's group for those who may read the journal; services name it in
    # SupplementaryGroups= (alloy), and without it they cannot start.
    users.groups.systemd-journal.gid = config.ids.gids.systemd-journal;

    environment.etc."units/echo-failures" = lib.mkIf cfg.echoFailures { text = ""; };
    environment.etc."units/console-log" = lib.mkIf (consoleTty != null) { text = "${consoleTty}\n"; };

    systemd.services.systemd-journald = lib.mkIf cfg.syslog.enable {
      description = "System Log (s6-socklog)";
      wantedBy = [ "sysinit.target" ];
      before = [ "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "syslogd";
      };
      stopIfChanged = false;
      serviceConfig = {
        ExecStart = "${pkgs.s6}/bin/s6-socklog -d 3 -t 2000";
        # s6-socklog announces readiness the s6 way, on a descriptor.
        X-NotifyFd = 3;
        Restart = "always";
        RestartSec = 1;
      };
    };

    # rsyslogd's messages come from the socket that journald would forward
    # to (`syslog.socket`; it requires it and reads $SystemLogSocketName).
    # Here nothing forwards, so the programs that call syslog(3) are sent
    # to it directly: /dev/log is another name for it.
    systemd.sockets.syslog = lib.mkIf rsyslogd {
      description = "Syslog Socket";
      wantedBy = [ "sockets.target" ];
      before = [ "sockets.target" ];
      unitConfig.DefaultDependencies = false;
      listenDatagrams = [ "/run/systemd/journal/syslog" ];
      socketConfig = {
        SocketMode = "0666";
        PassCredentials = true;
        PassSecurity = true;
        ReceiveBuffer = "8M";
      };
    };
    systemd.tmpfiles.rules = lib.optional (forward && !cfg.syslog.enable) "L+ /dev/log - - - - /run/systemd/journal/syslog";

    systemd.services.klogd = lib.mkIf cfg.kernel.enable {
      description = "Kernel Log";
      wantedBy = [ "sysinit.target" ];
      before = [ "sysinit.target" ];
      unitConfig.DefaultDependencies = false;
      stopIfChanged = false;
      serviceConfig = {
        ExecStart = "${pkgs.util-linux}/bin/dmesg --follow";
        Restart = "always";
        RestartSec = 1;
      };
    };
  };
}
