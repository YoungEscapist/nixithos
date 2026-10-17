#!/usr/bin/env python3
# org.freedesktop.systemd1 on a user's session bus, for the programs that
# speak to the user's service manager over D-Bus rather than through
# `systemctl --user`: gnome-session 49 and later starts the whole of GNOME
# that way (gnome-session-init-worker: GetUnit, StartUnit, ResetFailed and the
# ActiveState of graphical-session-pre.target; gnome-session-ctl: StartUnit,
# StopUnit), and uploads the session's environment with SetEnvironment.
#
# Every call is handed to the systemctl front-end of the s6 user manager;
# this is only the D-Bus face of it.  What it does not do is a D-Bus error
# (StartTransientUnit, which GLib and gnome-shell try for the scopes of the
# programs they start, falls back to a plain start on that).

import os
import subprocess
import sys
import threading

from gi.repository import Gio, GLib

SYSTEMCTL = os.environ.get("SYSTEMD1_BUS_SYSTEMCTL", "systemctl")
PATH = "/org/freedesktop/systemd1"

XML = """
<node>
  <interface name="org.freedesktop.systemd1.Manager">
    <method name="GetUnit"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="LoadUnit"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="StartUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="StopUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="RestartUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="TryRestartUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="ReloadUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="ResetFailed"/>
    <method name="ResetFailedUnit"><arg type="s" direction="in"/></method>
    <method name="SetEnvironment"><arg type="as" direction="in"/></method>
    <method name="UnsetEnvironment"><arg type="as" direction="in"/></method>
    <method name="UnsetAndSetEnvironment"><arg type="as" direction="in"/><arg type="as" direction="in"/></method>
    <method name="Subscribe"/>
    <method name="Unsubscribe"/>
    <signal name="JobRemoved"><arg type="u"/><arg type="o"/><arg type="s"/><arg type="s"/></signal>
    <property name="Environment" type="as" access="read"/>
    <property name="Version" type="s" access="read"/>
  </interface>
</node>
"""

UNIT_XML = """
<node>
  <interface name="org.freedesktop.systemd1.Unit">
    <property name="Id" type="s" access="read"/>
    <property name="LoadState" type="s" access="read"/>
    <property name="ActiveState" type="s" access="read"/>
    <property name="SubState" type="s" access="read"/>
  </interface>
</node>
"""

MANAGER_IFACE = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
UNIT_IFACE = Gio.DBusNodeInfo.new_for_xml(UNIT_XML).interfaces[0]


def escape(name):
    # systemd's bus_label_escape: [A-Za-z0-9] as they are, the rest as _xx
    return "".join(c if c.isascii() and c.isalnum() else "_%02x" % ord(c) for c in name) or "_"


def systemctl(*args):
    r = subprocess.run([SYSTEMCTL, "--user", *args], stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def error(inv, name, msg):
    inv.return_dbus_error(name, msg)


class Bus:
    def __init__(self, conn):
        self.conn = conn
        self.units = {}     # name -> [registration id, state dict]
        self.job = 0
        conn.register_object(PATH, MANAGER_IFACE, self.manager_call, self.manager_get, None)
        GLib.timeout_add_seconds(1, self.poll)

    # --- units

    def state(self, name):
        _, out, _ = systemctl("show", "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", name)
        st = {"LoadState": "not-found", "ActiveState": "inactive", "SubState": "dead"}
        for line in out.splitlines():
            k, _, v = line.partition("=")
            if k in st and v:
                st[k] = v
        return st

    def unit(self, name, load=False):
        if name in self.units:
            return PATH + "/unit/" + escape(name)
        st = self.state(name)
        if st["LoadState"] == "not-found" and not load:
            return None
        path = PATH + "/unit/" + escape(name)
        ent = [None, st]

        def get(conn, sender, obj, iface, prop):
            if prop == "Id":
                return GLib.Variant("s", name)
            return GLib.Variant("s", ent[1][prop])

        ent[0] = self.conn.register_object(path, UNIT_IFACE, None, get, None)
        self.units[name] = ent
        return path

    def poll(self):
        # (the ActiveState of the units somebody asked about, as
        # PropertiesChanged: the leader of gnome-session waits on it)
        for name, ent in list(self.units.items()):
            st = self.state(name)
            changed = {k: GLib.Variant("s", v) for k, v in st.items() if ent[1].get(k) != v}
            ent[1] = st
            if changed:
                self.conn.emit_signal(None, PATH + "/unit/" + escape(name),
                                      "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                      GLib.Variant("(sa{sv}as)", ("org.freedesktop.systemd1.Unit", changed, [])))
        return True

    # --- jobs: run in a thread, answered with JobRemoved

    def run_job(self, verb, name):
        self.job += 1
        jid = self.job
        path = "%s/job/%d" % (PATH, jid)

        def work():
            rc, _, err = systemctl(verb, name)
            if rc:
                print("systemd1-bus: %s %s: %s" % (verb, name, err), file=sys.stderr)
            GLib.idle_add(lambda: self.conn.emit_signal(
                None, PATH, "org.freedesktop.systemd1.Manager", "JobRemoved",
                GLib.Variant("(uoss)", (jid, path, name, "done" if rc == 0 else "failed"))) and False)

        threading.Thread(target=work, daemon=True).start()
        return path

    # --- the manager

    def manager_call(self, conn, sender, obj, iface, method, params, inv):
        p = params.unpack()
        if method in ("GetUnit", "LoadUnit"):
            path = self.unit(p[0], load=method == "LoadUnit")
            if path is None:
                return error(inv, "org.freedesktop.systemd1.NoSuchUnit", "Unit %s not loaded." % p[0])
            return inv.return_value(GLib.Variant("(o)", (path,)))
        if method in ("StartUnit", "StopUnit", "RestartUnit", "TryRestartUnit", "ReloadUnit"):
            verb = {"StartUnit": "start", "StopUnit": "stop", "RestartUnit": "restart",
                    "TryRestartUnit": "try-restart", "ReloadUnit": "reload"}[method]
            return inv.return_value(GLib.Variant("(o)", (self.run_job(verb, p[0]),)))
        if method == "ResetFailed":
            systemctl("reset-failed")
            return inv.return_value(None)
        if method == "ResetFailedUnit":
            systemctl("reset-failed", p[0])
            return inv.return_value(None)
        if method == "SetEnvironment":
            if p[0]:
                systemctl("set-environment", *p[0])
            return inv.return_value(None)
        if method == "UnsetEnvironment":
            if p[0]:
                systemctl("unset-environment", *p[0])
            return inv.return_value(None)
        if method == "UnsetAndSetEnvironment":
            if p[0]:
                systemctl("unset-environment", *p[0])
            if p[1]:
                systemctl("set-environment", *p[1])
            return inv.return_value(None)
        if method in ("Subscribe", "Unsubscribe"):
            return inv.return_value(None)
        error(inv, "org.freedesktop.DBus.Error.NotSupported", "%s is not supported here" % method)

    def manager_get(self, conn, sender, obj, iface, prop):
        if prop == "Environment":
            _, out, _ = systemctl("show-environment")
            return GLib.Variant("as", out.splitlines())
        if prop == "Version":
            return GLib.Variant("s", "s6 user manager")
        return None


def main():
    loop = GLib.MainLoop()
    state = {}

    def acquired(conn, name):
        print("systemd1-bus: %s on the session bus" % name, file=sys.stderr)

    def lost(conn, name):
        print("systemd1-bus: lost %s" % name, file=sys.stderr)
        loop.quit()

    def bus_acquired(conn, name):
        state["bus"] = Bus(conn)

    Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.systemd1",
                     Gio.BusNameOwnerFlags.NONE, bus_acquired, acquired, lost)
    loop.run()
    return 1


if __name__ == "__main__":
    sys.exit(main())
