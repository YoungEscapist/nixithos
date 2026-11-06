#!/usr/bin/env python3
# org.freedesktop.systemd1 on a user's session bus, for the programs that
# speak to the user's service manager over D-Bus rather than through
# `systemctl --user`: gnome-session 49 and later starts the whole of GNOME
# that way (gnome-session-init-worker: GetUnit, StartUnit, ResetFailed and the
# ActiveState of graphical-session-pre.target; gnome-session-ctl: StartUnit,
# StopUnit), and uploads the session's environment with SetEnvironment.
#
# Every call is handed to the systemctl front-end of the s6 user manager;
# static units keep their native manager. Transient user services/scopes
# use a delegated cgroup v2 subtree and a strictly checked property subset.

import os
import time
from pathlib import Path as FilePath
import signal

import transient
import subprocess
import sys
import threading

from gi.repository import Gio, GLib

SYSTEMCTL = os.environ.get("SYSTEMD1_BUS_SYSTEMCTL", "systemctl")
PATH = "/org/freedesktop/systemd1"

XML = """
<node>
  <interface name="org.freedesktop.systemd1.Manager">
    <method name="StartTransientUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="a(sv)" direction="in"/><arg type="a(sa(sv))" direction="in"/><arg type="o" direction="out"/></method>
    <method name="ListUnits"><arg type="a(ssssssouso)" direction="out"/></method>
    <method name="ListJobs"><arg type="a(usssoo)" direction="out"/></method>
    <method name="GetJob"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
    <method name="GetUnitByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
    <method name="KillUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="i" direction="in"/></method>
    <signal name="UnitNew"><arg type="s"/><arg type="o"/></signal>
    <signal name="UnitRemoved"><arg type="s"/><arg type="o"/></signal>
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
    <method name="Ref"/><method name="Unref"/>
    <property name="Description" type="s" access="read"/>
    <property name="Transient" type="b" access="read"/>
    <property name="ControlGroup" type="s" access="read"/>
    <property name="Slice" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="LoadState" type="s" access="read"/>
    <property name="ActiveState" type="s" access="read"/>
    <property name="SubState" type="s" access="read"/>
  </interface>
</node>
"""

SERVICE_XML = """<node><interface name="org.freedesktop.systemd1.Service">
  <property name="MainPID" type="u" access="read"/>
  <property name="ExecMainCode" type="i" access="read"/>
  <property name="ExecMainStatus" type="i" access="read"/>
  <property name="Result" type="s" access="read"/>
</interface></node>"""
SCOPE_XML = """<node><interface name="org.freedesktop.systemd1.Scope">
  <property name="Result" type="s" access="read"/>
</interface></node>"""
JOB_XML = """<node><interface name="org.freedesktop.systemd1.Job">
  <property name="Id" type="u" access="read"/>
  <property name="Unit" type="(so)" access="read"/>
  <property name="JobType" type="s" access="read"/>
  <property name="State" type="s" access="read"/>
</interface></node>"""
MANAGER_IFACE, UNIT_IFACE, SERVICE_IFACE, SCOPE_IFACE, JOB_IFACE = [
    Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
    for xml in (XML, UNIT_XML, SERVICE_XML, SCOPE_XML, JOB_XML)
]
TYPES = dict(Transient="b", MainPID="u", ExecMainCode="i", ExecMainStatus="i")


def variant(key, value):
    return GLib.Variant(TYPES.get(key, "s"), value)


def escape(name):
    # systemd's bus_label_escape: [A-Za-z0-9] as they are, the rest as _xx
    return (
        "".join(c if c.isascii() and c.isalnum() else "_%02x" % ord(c) for c in name)
        or "_"
    )


def systemctl(*args):
    r = subprocess.run(
        [SYSTEMCTL, "--user", *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def error(inv, name, msg):
    inv.return_dbus_error(name, msg)


class Bus:
    def __init__(self, conn):
        self.conn = conn
        self.watched = set()
        self.units = {}  # name -> [registration id, state dict]
        self.job = 0
        self.jobs = {}
        self.transients = {}
        self.environment = dict(os.environ)
        conn.register_object(
            PATH, MANAGER_IFACE, self.manager_call, self.manager_get, None
        )
        GLib.timeout_add_seconds(1, self.poll)
        GLib.timeout_add(100, self.poll_transients)
        conn.signal_subscribe(
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            None,
            Gio.DBusSignalFlags.NONE,
            self.owner_changed,
        )

    # --- units

    def state(self, name):
        if name in self.transients:
            return self.transients[name].state()
        _, out, _ = systemctl(
            "show", "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", name
        )
        st = {"LoadState": "not-found", "ActiveState": "inactive", "SubState": "dead"}
        for line in out.splitlines():
            k, _, v = line.partition("=")
            if k in st and v:
                st[k] = v
        return st

    def unit(self, name, load=False, st=None, watch=True):
        if watch:
            self.watched.add(name)
        if name in self.units:
            return PATH + "/unit/" + escape(name)
        if st is None:
            st = self.state(name)
        if st["LoadState"] == "not-found":
            return None
        path = PATH + "/unit/" + escape(name)
        ent = [None, st]

        def get(conn, sender, obj, iface, prop):
            if prop == "Id":
                return GLib.Variant("s", name)
            self.watched.add(name)
            defaults = dict(
                Description=name, Transient=False, ControlGroup="", Slice=""
            )
            value = ent[1].get(prop, defaults.get(prop))
            return variant(prop, value) if value is not None else None

        def call(conn, sender, obj, iface, method, params, inv):
            unit = self.transients.get(name)
            if not unit:
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.NotSupported",
                    "References are only supported for transient units",
                )
            if method == "Ref":
                unit.refs[sender] = unit.refs.get(sender, 0) + 1
            elif method == "Unref":
                if unit.refs.get(sender, 0) <= 1:
                    unit.refs.pop(sender, None)
                else:
                    unit.refs[sender] -= 1
            else:
                return error(inv, "org.freedesktop.DBus.Error.NotSupported", method)
            inv.return_value(None)

        ent[0] = [self.conn.register_object(path, UNIT_IFACE, call, get, None)]
        if name in self.transients:
            extra = SCOPE_IFACE if self.transients[name].scope else SERVICE_IFACE
            ent[0].append(self.conn.register_object(path, extra, None, get, None))
        self.units[name] = ent
        return path

    def update(self, name):
        ent = self.units.get(name)
        if not ent:
            return
        state = self.state(name)
        for iface in (
            UNIT_IFACE,
            SCOPE_IFACE if name.endswith(".scope") else SERVICE_IFACE,
        ):
            keys = {p.name for p in iface.properties}
            changed = {
                k: variant(k, v)
                for k, v in state.items()
                if k in keys and ent[1].get(k) != v
            }
            if changed:
                self.conn.emit_signal(
                    None,
                    PATH + "/unit/" + escape(name),
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                    GLib.Variant("(sa{sv}as)", (iface.name, changed, [])),
                )
        ent[1] = state

    def poll(self):
        # (the ActiveState of the units somebody asked about, as
        # PropertiesChanged: the leader of gnome-session waits on it)
        for name in list(self.watched):
            if name in self.units and name not in self.transients:
                self.update(name)
        return True

    def poll_transients(self):
        for name, unit in list(self.transients.items()):
            try:
                unit.poll()
            except OSError as exc:
                print("systemd1-bus: poll %s: %s" % (name, exc), file=sys.stderr)
                unit.abort_start()
            self.update(name)
            if (
                unit.exited_at
                and not unit.refs
                and unit.active != "active"
                and not unit.done
            ):
                if unit.active != "failed" or unit.collect == "inactive-or-failed":
                    if time.monotonic() - unit.exited_at > 2:
                        self.remove(name)
        return True

    def owner_changed(self, conn, sender, obj, iface, sig, params):
        name, old, new = params.unpack()
        if name.startswith(":") and old and not new:
            for unit in self.transients.values():
                unit.refs.pop(name, None)

    def remove(self, name):
        self.transients.pop(name)
        self.watched.discard(name)
        entry = self.units.pop(name, None)
        if entry:
            for registration in entry[0]:
                self.conn.unregister_object(registration)
            self.conn.emit_signal(
                None,
                PATH,
                MANAGER_IFACE.name,
                "UnitRemoved",
                GLib.Variant("(so)", (name, PATH + "/unit/" + escape(name))),
            )

    def make_job(self, verb, name):
        self.job += 1
        jid, path = self.job, "%s/job/%d" % (PATH, self.job)

        def get(conn, sender, obj, iface, prop):
            return {
                "Id": GLib.Variant("u", jid),
                "Unit": GLib.Variant("(so)", (name, PATH + "/unit/" + escape(name))),
                "JobType": GLib.Variant("s", verb),
                "State": GLib.Variant("s", "running"),
            }.get(prop)

        registration = self.conn.register_object(path, JOB_IFACE, None, get, None)
        self.jobs[jid] = (name, verb, path, registration)

        def done(result):
            if jid not in self.jobs:
                return
            self.update(name)
            self.conn.emit_signal(
                None,
                PATH,
                MANAGER_IFACE.name,
                "JobRemoved",
                GLib.Variant("(uoss)", (jid, path, name, result)),
            )
            self.conn.unregister_object(registration)
            del self.jobs[jid]

        return path, done

    def run_job(self, verb, name):
        path, done = self.make_job(verb, name)
        if name in self.transients:
            unit = self.transients[name]

            def work():
                try:
                    if verb == "start":
                        if unit.active == "active":
                            done("done")
                        else:
                            unit.start(done)
                    elif verb == "try-restart" and unit.active != "active":
                        done("done")
                    else:
                        unit.stop(done, restart=verb in ("restart", "try-restart"))
                except (OSError, ValueError) as exc:
                    print("systemd1-bus: %s: %s" % (name, exc), file=sys.stderr)
                    unit.done = done
                    unit.abort_start()
                return False

            GLib.idle_add(work)
        else:

            def work():
                rc, _, err = systemctl(verb, name)
                if rc:
                    print("systemd1-bus: %s: %s" % (name, err), file=sys.stderr)
                GLib.idle_add(lambda: done("done" if rc == 0 else "failed"))

            threading.Thread(target=work, daemon=True).start()
        return path

    def close(self):
        for unit in self.transients.values():
            if unit.created and unit.group.exists():
                try:
                    transient.send(unit.group, signal.SIGKILL)
                except OSError:
                    pass

    # --- the manager

    def manager_call(self, conn, sender, obj, iface, method, params, inv):
        p = params.unpack()
        if method == "StartTransientUnit":
            name, mode, props, auxiliary = p
            if mode not in ("fail", "replace") or auxiliary:
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.NotSupported",
                    "Unsupported job mode or auxiliary units",
                )
            if name in self.transients or self.state(name)["LoadState"] != "not-found":
                return error(
                    inv, "org.freedesktop.systemd1.UnitExists", "Unit already exists"
                )
            if len(self.transients) >= 512:
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.LimitsExceeded",
                    "Too many transient units",
                )
            values = {}
            raw = params.get_child_value(2)
            try:
                for i in range(raw.n_children()):
                    item = raw.get_child_value(i)
                    key, value = (
                        item.get_child_value(0).get_string(),
                        item.get_child_value(1).get_variant(),
                    )
                    if key not in transient.SIGNATURES:
                        raise transient.Unsupported(
                            "Unsupported transient property: " + key
                        )
                    if (
                        key in values
                        or value.get_type_string() != transient.SIGNATURES[key]
                    ):
                        raise ValueError(
                            "Duplicate or incorrectly typed property: " + key
                        )
                    values[key] = value.unpack()
                environment = dict(self.environment)
                # Native import-environment/set-environment updates are shared
                # with transient services, including late DISPLAY imports.
                native_state = os.environ.get("UNIT_USER_STATE")
                if native_state:
                    directory = FilePath(native_state) / "units" / ".env"
                    if directory.is_dir():
                        for file in directory.iterdir():
                            if transient.ENV.fullmatch(file.name) and file.is_file():
                                environment[file.name] = file.read_text()
                unit = transient.Unit(
                    name,
                    values,
                    sender,
                    os.environ.get("SYSTEMD1_CGROUP_ROOT"),
                    environment,
                )
            except transient.Unsupported as exc:
                return error(inv, "org.freedesktop.DBus.Error.NotSupported", str(exc))
            except (ValueError, TypeError) as exc:
                return error(inv, "org.freedesktop.DBus.Error.InvalidArgs", str(exc))
            except OSError as exc:
                return error(inv, "org.freedesktop.DBus.Error.Failed", str(exc))
            if name in self.units:
                for registration in self.units.pop(name)[0]:
                    self.conn.unregister_object(registration)
            self.transients[name] = unit
            objpath = self.unit(name, load=True)
            self.conn.emit_signal(
                None,
                PATH,
                MANAGER_IFACE.name,
                "UnitNew",
                GLib.Variant("(so)", (name, objpath)),
            )
            return inv.return_value(GLib.Variant("(o)", (self.run_job("start", name),)))
        if method == "ListUnits":
            # Include native units even if no client requested their object yet.
            rc, output, message = systemctl("list-units", "--all", "--no-legend")
            if rc:
                return error(inv, "org.freedesktop.DBus.Error.Failed", message)
            for line in output.splitlines():
                fields = line.split(None, 4)
                if len(fields) >= 4 and fields[1] == "loaded":
                    state = dict(
                        LoadState=fields[1],
                        ActiveState=fields[2],
                        SubState=fields[3],
                        Description=fields[4] if len(fields) > 4 else fields[0],
                    )
                    self.unit(fields[0], load=True, st=state, watch=False)
                    self.units[fields[0]][1].update(state)
            pending = {
                name: (jid, verb, path)
                for jid, (name, verb, path, reg) in self.jobs.items()
            }
            rows = [
                (
                    name,
                    entry[1].get("Description", name),
                    entry[1]["LoadState"],
                    entry[1]["ActiveState"],
                    entry[1]["SubState"],
                    "",
                    PATH + "/unit/" + escape(name),
                    *pending.get(name, (0, "", "/")),
                )
                for name, entry in self.units.items()
            ]
            return inv.return_value(GLib.Variant("(a(ssssssouso))", (rows,)))
        if method == "ListJobs":
            rows = [
                (jid, name, verb, "running", path, PATH + "/unit/" + escape(name))
                for jid, (name, verb, path, registration) in self.jobs.items()
            ]
            return inv.return_value(GLib.Variant("(a(usssoo))", (rows,)))
        if method == "GetJob":
            job = self.jobs.get(p[0])
            if not job:
                return error(inv, "org.freedesktop.systemd1.NoSuchJob", "No such job")
            return inv.return_value(GLib.Variant("(o)", (job[2],)))
        if method == "GetUnitByPID":
            for name, unit in self.transients.items():
                if (
                    unit.created
                    and unit.group.exists()
                    and p[0] in transient.cg_pids(unit.group)
                ):
                    return inv.return_value(GLib.Variant("(o)", (self.unit(name),)))
            return error(
                inv,
                "org.freedesktop.systemd1.NoUnitForPID",
                "PID is not in a tracked transient unit",
            )
        if method == "KillUnit":
            unit = self.transients.get(p[0])
            if not unit:
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.NotSupported",
                    "KillUnit supports transient units only",
                )
            if not unit.created or not unit.group.exists():
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.Failed",
                    "Unit has no managed processes",
                )
            if p[1] not in ("all", "main") or p[2] <= 0 or p[2] >= signal.NSIG:
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "Invalid signal or process selector",
                )
            try:
                if p[1] == "all":
                    transient.send(unit.group, p[2])
                elif unit.proc and unit.proc.poll() is None:
                    unit.proc.send_signal(p[2])
                else:
                    raise ProcessLookupError("No main process")
            except OSError as exc:
                return error(inv, "org.freedesktop.DBus.Error.Failed", str(exc))
            return inv.return_value(None)
        if method in ("GetUnit", "LoadUnit"):
            path = self.unit(p[0], load=method == "LoadUnit")
            if path is None:
                return error(
                    inv,
                    "org.freedesktop.systemd1.NoSuchUnit",
                    "Unit %s not loaded." % p[0],
                )
            return inv.return_value(GLib.Variant("(o)", (path,)))
        if method in (
            "StartUnit",
            "StopUnit",
            "RestartUnit",
            "TryRestartUnit",
            "ReloadUnit",
        ):
            if p[1] not in ("fail", "replace"):
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.NotSupported",
                    "Unsupported job mode",
                )
            if any(job[0] == p[0] for job in self.jobs.values()):
                return error(
                    inv,
                    "org.freedesktop.systemd1.TransactionIsDestructive",
                    "A job for this unit is already running",
                )
            unit = self.transients.get(p[0])
            if unit and (
                method == "ReloadUnit"
                or (unit.scope and method in ("RestartUnit", "TryRestartUnit"))
            ):
                return error(
                    inv,
                    "org.freedesktop.DBus.Error.NotSupported",
                    "Operation is not supported for this transient unit",
                )
            if not unit and self.unit(p[0], load=True) is None:
                return error(
                    inv, "org.freedesktop.systemd1.NoSuchUnit", "No such native unit"
                )
            verb = {
                "StartUnit": "start",
                "StopUnit": "stop",
                "RestartUnit": "restart",
                "TryRestartUnit": "try-restart",
                "ReloadUnit": "reload",
            }[method]
            return inv.return_value(GLib.Variant("(o)", (self.run_job(verb, p[0]),)))
        if method == "ResetFailed":
            for name, unit in self.transients.items():
                if unit.active == "failed":
                    unit.active, unit.sub, unit.result = "inactive", "dead", "success"
                    self.update(name)
            systemctl("reset-failed")
            return inv.return_value(None)
        if method == "ResetFailedUnit" and p[0] in self.transients:
            unit = self.transients[p[0]]
            if unit.active == "failed":
                unit.active, unit.sub, unit.result = "inactive", "dead", "success"
                self.update(p[0])
            return inv.return_value(None)
        if method == "ResetFailedUnit":
            systemctl("reset-failed", p[0])
            return inv.return_value(None)
        if method == "SetEnvironment":
            for item in p[0]:
                key, sep, value = item.partition("=")
                if not sep or not transient.ENV.fullmatch(key):
                    return error(
                        inv,
                        "org.freedesktop.DBus.Error.InvalidArgs",
                        "Invalid environment assignment",
                    )
            for item in p[0]:
                key, _, value = item.partition("=")
                self.environment[key] = value
            if p[0]:
                systemctl("set-environment", *p[0])
            return inv.return_value(None)
        if method == "UnsetEnvironment":
            for key in p[0]:
                self.environment.pop(key, None)
            if p[0]:
                systemctl("unset-environment", *p[0])
            return inv.return_value(None)
        if method == "UnsetAndSetEnvironment":
            for item in p[1]:
                key, sep, value = item.partition("=")
                if not sep or not transient.ENV.fullmatch(key):
                    return error(
                        inv,
                        "org.freedesktop.DBus.Error.InvalidArgs",
                        "Invalid environment assignment",
                    )
            for key in p[0]:
                self.environment.pop(key, None)
            for item in p[1]:
                key, _, value = item.partition("=")
                self.environment[key] = value
            if p[0]:
                systemctl("unset-environment", *p[0])
            if p[1]:
                systemctl("set-environment", *p[1])
            return inv.return_value(None)
        if method in ("Subscribe", "Unsubscribe"):
            return inv.return_value(None)
        error(
            inv,
            "org.freedesktop.DBus.Error.NotSupported",
            "%s is not supported here" % method,
        )

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

    Gio.bus_own_name(
        Gio.BusType.SESSION,
        "org.freedesktop.systemd1",
        Gio.BusNameOwnerFlags.NONE,
        bus_acquired,
        acquired,
        lost,
    )
    GLib.unix_signal_add(
        GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: loop.quit() or False
    )
    GLib.unix_signal_add(
        GLib.PRIORITY_DEFAULT, signal.SIGINT, lambda: loop.quit() or False
    )
    try:
        loop.run()
    finally:
        if "bus" in state:
            state["bus"].close()
    return 1


if __name__ == "__main__":
    sys.exit(main())
