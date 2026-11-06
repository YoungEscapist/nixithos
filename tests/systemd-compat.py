"""A real session-bus client; run as an ordinary user inside the VM."""

import os
from pathlib import Path
import signal
import subprocess
import time
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
manager = "/org/freedesktop/systemd1"
interface = "org.freedesktop.systemd1.Manager"
events, changes = {}, []
bus.signal_subscribe(
    "org.freedesktop.systemd1",
    interface,
    "JobRemoved",
    manager,
    None,
    Gio.DBusSignalFlags.NONE,
    lambda c, s, o, i, n, p: events.update({p.unpack()[1]: p.unpack()[3]}),
)
bus.signal_subscribe(
    "org.freedesktop.systemd1",
    "org.freedesktop.DBus.Properties",
    "PropertiesChanged",
    None,
    None,
    Gio.DBusSignalFlags.NONE,
    lambda c, s, o, i, n, p: changes.append((o, p.unpack())),
)


def call(method, signature, args, path=manager, iface=interface):
    params = GLib.Variant(signature, args) if signature else None
    return bus.call_sync(
        "org.freedesktop.systemd1",
        path,
        iface,
        method,
        params,
        None,
        Gio.DBusCallFlags.NONE,
        15000,
        None,
    ).unpack()


def spin(predicate, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("Timed out waiting for D-Bus state; jobs=" + repr(events))


def wait_job(path, result="done"):
    spin(lambda: path in events)
    actual = events.pop(path)
    assert actual == result, (path, actual, result)


def prop(path, key, iface="org.freedesktop.systemd1.Unit"):
    return call("Get", "(ss)", (iface, key), path, "org.freedesktop.DBus.Properties")[0]


def unit(name):
    return call("GetUnit", "(s)", (name,))[0]


def create(name, properties):
    properties["AddRef"] = GLib.Variant("b", True)
    return call(
        "StartTransientUnit",
        "(ssa(sv)a(sa(sv)))",
        (name, "fail", list(properties.items()), []),
    )[0]


def reject(name, properties, expected="NotSupported"):
    try:
        create(name, properties)
    except GLib.Error as error:
        assert expected in str(error), error
    else:
        raise AssertionError("Unsupported request succeeded: " + name)


def operation(name, method):
    wait_job(call(method, "(ss)", (name, "replace"))[0])


sleep = "/run/current-system/sw/bin/sleep"
sh = "/run/current-system/sw/bin/sh"
exec_start = lambda args: GLib.Variant("a(sasb)", [(args[0], args, False)])
service = {"Type": GLib.Variant("s", "exec"), "ExecStart": exec_start([sleep, "10000"])}
reject("../escape.service", dict(service), "InvalidArgs")
reject("unsupported.service", {**service, "MemoryMax": GLib.Variant("t", 1)})
reject("notify.service", {**service, "Type": GLib.Variant("s", "notify")})
reject(
    "bad-type.service", {**service, "Description": GLib.Variant("u", 3)}, "InvalidArgs"
)
reject(
    "duplicate.service",
    {
        "ExecStart": GLib.Variant("a(sasb)", [(sleep, [sleep, "1"], False)]),
        "Type": GLib.Variant("s", "forking"),
    },
)

call("SetEnvironment", "(as)", (["FROM_MANAGER=managed"],))
subprocess.run(["systemctl", "--user", "set-environment", "FROM_CLI=cli"], check=True)
job = create(
    "probe.service",
    {
        **service,
        "Environment": GLib.Variant("as", ["OWN_VAR=local"]),
        "WorkingDirectory": GLib.Variant("s", "/home/alice"),
        "ExecStart": exec_start(
            [
                sh,
                "-c",
                'printf "%s|%s|%s|%s" "$FROM_MANAGER" "$OWN_VAR" "$PWD" "$FROM_CLI" > "$XDG_RUNTIME_DIR/probe.out"; exec sleep 10000',
            ]
        ),
    },
)
wait_job(job)
obj = unit("probe.service")
assert prop(obj, "Transient") is True
assert prop(obj, "ActiveState") == "active"
pid = prop(obj, "MainPID", "org.freedesktop.systemd1.Service")
assert Path("/proc", str(pid)).stat().st_uid == os.getuid()
cgroup = prop(obj, "ControlGroup")
assert cgroup in Path("/proc", str(pid), "cgroup").read_text()
assert "nixith-compat-1000" in cgroup
spin(lambda: Path(os.environ["XDG_RUNTIME_DIR"], "probe.out").exists())
assert (
    Path(os.environ["XDG_RUNTIME_DIR"], "probe.out").read_text()
    == "managed|local|/home/alice|cli"
)
assert call("GetUnitByPID", "(u)", (pid,))[0] == obj
reject("probe.service", dict(service), "UnitExists")
operation("probe.service", "RestartUnit")
new_pid = prop(obj, "MainPID", "org.freedesktop.systemd1.Service")
assert new_pid != pid and new_pid > 1
operation("probe.service", "StopUnit")
assert prop(obj, "ActiveState") == "inactive"
assert not Path("/proc", str(new_pid)).exists()
assert not Path("/sys/fs/cgroup" + cgroup).exists()

# A slow oneshot keeps a real job object while calls remain responsive.
job = create(
    "oneshot.service",
    {
        "Type": GLib.Variant("s", "oneshot"),
        "RemainAfterExit": GLib.Variant("b", True),
        "ExecStart": exec_start([sleep, "1"]),
    },
)
assert any(entry[1] == "oneshot.service" for entry in call("ListJobs", "", ())[0])
assert call("GetJob", "(u)", (int(job.rsplit("/", 1)[1]),))[0] == job
wait_job(job)
assert prop(unit("oneshot.service"), "SubState") == "exited"
operation("oneshot.service", "StopUnit")

job = create(
    "fails.service",
    {
        "Type": GLib.Variant("s", "oneshot"),
        "ExecStart": exec_start([sh, "-c", "exit 7"]),
    },
)
wait_job(job, "failed")
assert (
    prop(unit("fails.service"), "ExecMainStatus", "org.freedesktop.systemd1.Service")
    == 7
)
assert prop(unit("fails.service"), "ActiveState") == "failed"
call("ResetFailedUnit", "(s)", ("fails.service",))
assert prop(unit("fails.service"), "ActiveState") == "inactive"
job = create(
    "missing.service",
    {"Type": GLib.Variant("s", "exec"), "ExecStart": exec_start(["/does-not-exist"])},
)
wait_job(job, "failed")
assert prop(unit("missing.service"), "ActiveState") == "failed"

# A scope adopts existing processes from the same delegated user subtree.
child = subprocess.Popen([sleep, "10000"])
try:
    job = create(
        "external.scope",
        {
            "PIDs": GLib.Variant("au", [child.pid]),
            "Description": GLib.Variant("s", "test scope"),
        },
    )
    wait_job(job)
    scope = unit("external.scope")
    group = prop(scope, "ControlGroup")
    assert group in Path("/proc", str(child.pid), "cgroup").read_text()
    operation("external.scope", "StopUnit")
    child.wait(timeout=5)
    assert prop(scope, "ActiveState") == "inactive"
    assert not Path("/sys/fs/cgroup" + group).exists()
finally:
    if child.poll() is None:
        child.kill()
        child.wait()

# Existing groups and processes belonging to another UID are never adopted.
foreign = int(Path(os.environ["XDG_RUNTIME_DIR"], "foreign.pid").read_text())
wait_job(create("foreign.scope", {"PIDs": GLib.Variant("au", [foreign])}), "failed")
assert Path("/proc", str(foreign)).exists()
root = Path(os.environ["SYSTEMD1_CGROUP_ROOT"])
stale = root / "app.slice" / "stale.service"
stale.mkdir()
sentinel = subprocess.Popen([sleep, "10000"])
try:
    (stale / "cgroup.procs").write_text(str(sentinel.pid))
    wait_job(create("stale.service", dict(service)), "failed")
    assert sentinel.poll() is None, "Failed creation killed a pre-existing cgroup"
    try:
        call("KillUnit", "(ssi)", ("stale.service", "all", int(signal.SIGKILL)))
    except GLib.Error:
        pass
    else:
        raise AssertionError("A failed unit claimed a pre-existing cgroup")
    operation("stale.service", "StopUnit")
    assert sentinel.poll() is None, "Stop touched a pre-existing cgroup"
finally:
    sentinel.terminate()
    sentinel.wait()
    stale.rmdir()

# Descendants that create a new process session are still in the unit cgroup.
script = 'setsid sleep 10000 & echo $! > "$XDG_RUNTIME_DIR/grandchild"; wait'
wait_job(
    create("tree.service", {**service, "ExecStart": exec_start([sh, "-c", script])})
)
marker = Path(os.environ["XDG_RUNTIME_DIR"], "grandchild")
spin(marker.exists)
grandchild = int(marker.read_text())
operation("tree.service", "StopUnit")
spin(
    lambda: (
        not Path("/proc", str(grandchild)).exists()
        or ") Z " in Path("/proc", str(grandchild), "stat").read_text()
    )
)

# Stop timeout kills the cgroup and reports timeout instead of fake success.
script = 'trap "" TERM; echo ready > "$XDG_RUNTIME_DIR/ignore-term"; exec sleep 10000'
wait_job(
    create(
        "timeout.service",
        {
            **service,
            "ExecStart": exec_start([sh, "-c", script]),
            "TimeoutStopUSec": GLib.Variant("t", 200000),
        },
    )
)
spin(lambda: Path(os.environ["XDG_RUNTIME_DIR"], "ignore-term").exists())
obj_timeout = unit("timeout.service")
wait_job(call("StopUnit", "(ss)", ("timeout.service", "replace"))[0], "timeout")
assert prop(obj_timeout, "Result", "org.freedesktop.systemd1.Service") == "timeout"
assert prop(obj_timeout, "ActiveState") == "failed"
assert not Path("/sys/fs/cgroup" + prop(obj_timeout, "ControlGroup")).exists()

names = [row[0] for row in call("ListUnits", "", ())[0]]
assert "probe.service" in names and "native.service" in names
assert any(path == obj and "ActiveState" in values[1] for path, values in changes)
# Unref permits collection; failed units can opt in to collection as well.
call("Unref", "", (), obj, "org.freedesktop.systemd1.Unit")
spin(lambda: "probe.service" not in [row[0] for row in call("ListUnits", "", ())[0]])
operation("native.service", "StartUnit")
assert prop(unit("native.service"), "ActiveState") == "active"
operation("native.service", "StopUnit")
print(
    "PASS: real user D-Bus services/scopes, jobs/signals, cgroups, failure semantics and native units"
)
