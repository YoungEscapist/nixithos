"""A small, strict transient user-unit runtime backed by delegated cgroup v2."""

import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


class Unsupported(ValueError):
    pass


SIGNATURES = {
    "Description": "s",
    "Type": "s",
    "ExecStart": "a(sasb)",
    "Environment": "as",
    "WorkingDirectory": "s",
    "PIDs": "au",
    "RemainAfterExit": "b",
    "TimeoutStopUSec": "t",
    "Slice": "s",
    "AddRef": "b",
    "CollectMode": "s",
}
NAME = re.compile(r"[A-Za-z0-9_:@.-]+\.(service|scope)\Z")
ENV = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def cg_pids(group):
    result = set()
    for file in group.rglob("cgroup.procs"):
        try:
            result.update(int(p) for p in file.read_text().split())
        except FileNotFoundError:
            pass
    return result


def populated(group):
    return "populated 1" in (group / "cgroup.events").read_text()


def send(group, sig):
    if sig == signal.SIGKILL:
        (group / "cgroup.kill").write_text("1")
        return
    for pid in cg_pids(group):
        try:
            fd = os.pidfd_open(pid)
            try:
                signal.pidfd_send_signal(fd, sig)
            finally:
                os.close(fd)
        except ProcessLookupError:
            pass


def remove_group(group):
    for child in sorted(group.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if child.is_dir():
            child.rmdir()
    group.rmdir()


class Unit:
    def __init__(self, name, props, owner, root, environment):
        if len(name) > 240 or not NAME.fullmatch(name):
            raise ValueError("Only plain .service and .scope names are supported")
        self.name, self.props = name, props
        self.scope = name.endswith(".scope")
        self.refs = {owner: 1} if props.get("AddRef", False) else {}
        self.collect = props.get("CollectMode", "inactive")
        if self.collect not in ("inactive", "inactive-or-failed"):
            raise ValueError("Invalid CollectMode")
        for key in props:
            if key not in SIGNATURES:
                raise Unsupported("Unsupported transient property: " + key)
        self.kind = props.get("Type", "simple")
        if self.kind not in ("simple", "exec", "oneshot"):
            raise Unsupported("Only simple, exec and oneshot services are supported")
        if self.scope and any(
            k in props
            for k in (
                "ExecStart",
                "Type",
                "Environment",
                "WorkingDirectory",
                "RemainAfterExit",
            )
        ):
            raise ValueError("Service properties cannot be used on a scope")
        if not self.scope and "PIDs" in props:
            raise ValueError("PIDs is only valid on a scope")
        self.slice = props.get("Slice", "app.slice")
        if self.slice not in ("app.slice", "background.slice", "session.slice"):
            raise Unsupported("Unsupported slice: " + self.slice)
        self.timeout = props.get("TimeoutStopUSec", 5_000_000) / 1_000_000
        if not 0 < self.timeout <= 300:
            raise Unsupported("TimeoutStopUSec must be between 1 and 300000000")
        self.env = dict(environment)
        for item in props.get("Environment", []):
            key, sep, value = item.partition("=")
            if not sep or not ENV.fullmatch(key) or "\0" in value:
                raise ValueError("Invalid environment assignment")
            self.env[key] = value
        self.cwd = props.get("WorkingDirectory", os.environ.get("HOME", "/"))
        if not self.cwd.startswith("/"):
            raise ValueError("WorkingDirectory must be absolute")
        self.argv, self.executable, self.ignore = [], "", False
        if not self.scope:
            commands = props.get("ExecStart", [])
            if len(commands) != 1:
                raise Unsupported("Exactly one ExecStart command is required")
            self.executable, self.argv, self.ignore = commands[0]
            if (
                not self.executable.startswith("/")
                or not self.argv
                or any("\0" in v for v in [self.executable, *self.argv])
            ):
                raise ValueError(
                    "ExecStart requires an absolute executable and nonempty argv"
                )
        elif not props.get("PIDs") or any(
            p <= 1 or p == os.getpid() for p in props["PIDs"]
        ):
            raise ValueError("A scope requires PIDs greater than one")
        if not root:
            raise Unsupported("This user manager has no delegated cgroup v2 subtree")
        self.root = Path(root).resolve()
        if (
            not self.root.is_relative_to("/sys/fs/cgroup")
            or not (self.root / "cgroup.controllers").is_file()
        ):
            raise Unsupported("A real cgroup v2 subtree is required")
        if not os.access(self.root / "cgroup.procs", os.W_OK):
            raise Unsupported("The cgroup subtree is not writable by this user")
        self.group = self.root / self.slice / name
        self.active, self.sub, self.result = "inactive", "dead", "success"
        self.created = False
        self.proc = None
        self.fd = None
        self.exec_error = b""
        self.started = False
        self.done = None
        self.stopping = False
        self.restart = False
        self.exited_at = None
        self.code = self.status = 0

    def state(self):
        return dict(
            LoadState="loaded",
            ActiveState=self.active,
            SubState=self.sub,
            Description=self.props.get("Description", self.name),
            Transient=True,
            ControlGroup=str(self.group).removeprefix("/sys/fs/cgroup"),
            Slice=self.slice,
            MainPID=self.proc.pid if self.proc and self.proc.poll() is None else 0,
            Result=self.result,
            ExecMainCode=self.code,
            ExecMainStatus=self.status,
        )

    def start(self, done):
        self.done, self.exited_at = done, None
        self.started, self.stopping, self.exec_error = False, False, b""
        self.result, self.code, self.status = "success", 0, 0
        self.created = False
        self.group.parent.mkdir(exist_ok=True)
        self.group.mkdir()  # do not adopt an existing or stale cgroup
        self.created = True
        self.active, self.sub = "activating", "start"
        if self.scope:
            # Preflight every PID before moving any of them. The kernel also
            # enforces migration permissions at the common cgroup ancestor.
            for pid in self.props["PIDs"]:
                if Path("/proc", str(pid)).stat().st_uid != os.geteuid():
                    raise PermissionError("Scope processes must belong to the bus user")
            moved = []
            try:
                for pid in self.props["PIDs"]:
                    original = (
                        Path("/proc", str(pid), "cgroup")
                        .read_text()
                        .strip()
                        .split("::", 1)[1]
                    )
                    (self.group / "cgroup.procs").write_text(str(pid))
                    moved.append((pid, original))
            except OSError:
                for pid, original in moved:
                    try:
                        (Path("/sys/fs/cgroup" + original) / "cgroup.procs").write_text(
                            str(pid)
                        )
                    except OSError:
                        pass
                raise
            self.active, self.sub, self.started = "active", "running", True
            self.complete("done")
            return
        self.fd, writefd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
        directory = Path(os.environ["XDG_RUNTIME_DIR"]) / "systemd-compat" / "logs"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            with open(directory / self.name, "ab", buffering=0) as log:
                self.proc = subprocess.Popen(
                    [
                        sys.executable,
                        __file__,
                        "--exec",
                        str(writefd),
                        str(self.group),
                        self.executable,
                        *self.argv,
                    ],
                    env=self.env,
                    cwd=self.cwd,
                    pass_fds=(writefd,),
                    start_new_session=True,
                    stdout=log,
                    stderr=log,
                )
        finally:
            os.close(writefd)

    def complete(self, result):
        if self.done:
            done, self.done = self.done, None
            done(result)

    def stop(self, done, restart=False):
        if self.scope and restart:
            raise Unsupported("An external scope cannot be restarted")
        self.done, self.restart = done, restart
        self.stopping = True
        self.timed_out = False
        self.active, self.sub = "deactivating", "stop"
        self.deadline = time.monotonic() + self.timeout
        if self.created and self.group.exists():
            send(self.group, signal.SIGTERM)

    def poll(self):
        if self.fd is not None:
            try:
                data = os.read(self.fd, 65536)
            except BlockingIOError:
                data = None
            if data:
                self.exec_error += data
            elif data == b"":
                os.close(self.fd)
                self.fd = None
                self.started = not self.exec_error
                if self.started and self.kind != "oneshot":
                    self.active, self.sub = "active", "running"
                    self.complete("done")
        rc = self.proc.poll() if self.proc else None
        alive = self.created and self.group.exists() and populated(self.group)
        if self.stopping:
            if alive and time.monotonic() >= self.deadline:
                self.timed_out = True
                send(self.group, signal.SIGKILL)
            if alive or (self.proc and rc is None):
                return
            if self.created and self.group.exists():
                remove_group(self.group)
                self.created = False
            if self.proc and rc is not None:
                self.code, self.status = (2, -rc) if rc < 0 else (1, rc)
            self.active, self.sub, self.result = (
                ("failed", "failed", "timeout")
                if self.timed_out
                else ("inactive", "dead", "success")
            )
            self.exited_at = time.monotonic()
            self.stopping = False
            if self.restart and not self.timed_out:
                self.restart = False
                done, self.done = self.done, None
                self.start(done)
            else:
                self.complete("timeout" if self.timed_out else "done")
            return
        ended = (
            not alive
            if self.scope
            else self.proc is not None and rc is not None and self.fd is None
        )
        if not ended or self.exited_at is not None:
            return
        # Main process exit also terminates descendants, including ones that
        # create a new session. Never substitute a process-group-only cleanup.
        if alive:
            send(self.group, signal.SIGKILL)
            return
        if self.created and self.group.exists():
            remove_group(self.group)
            self.created = False
        self.exited_at = time.monotonic()
        if not self.scope:
            self.code, self.status = (2, -rc) if rc < 0 else (1, rc)
        failed = bool(self.exec_error) or (
            not self.scope and rc != 0 and not self.ignore
        )
        self.result = (
            "resources"
            if self.exec_error
            else (("signal" if rc < 0 else "exit-code") if failed else "success")
        )
        self.active, self.sub = (
            ("failed", "failed")
            if failed
            else (
                ("active", "exited")
                if self.props.get("RemainAfterExit", False)
                else ("inactive", "dead")
            )
        )
        self.complete("failed" if failed else "done")

    def abort_start(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        if self.created and self.group.exists():
            if populated(self.group):
                if not self.scope:
                    send(self.group, signal.SIGKILL)
            else:
                remove_group(self.group)
                self.created = False
        self.active, self.sub, self.result = "failed", "failed", "resources"
        self.exited_at = time.monotonic()
        self.complete("failed")


if __name__ == "__main__":
    fd, group, executable, *argv = sys.argv[2:]
    fd = int(fd)
    os.set_inheritable(fd, False)
    try:
        (Path(group) / "cgroup.procs").write_text(str(os.getpid()))
        os.execve(executable, argv, os.environ)
    except OSError as error:
        os.write(fd, str(error).encode()[:4096])
        os._exit(203)
