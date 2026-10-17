#!/usr/bin/env python3
"""unitc - compile systemd unit files into an s6-rc source tree.

NixOS describes every daemon, mount and boot step as a systemd unit.  This
program reads the unit directory NixOS generates and writes the equivalent
s6-rc service definitions, so that the same configuration boots on
s6-linux-init + s6-rc.  It runs at build time only; nothing of it is needed
on the target system.

The mapping, in short:

  foo.service, Type=oneshot      oneshot  "foo"
  foo.service, any other type    longrun  "foo", logged by longrun "foo-log";
                                 plus oneshot "foo-hooks" when the unit has
                                 ExecStop= (s6 has no pre-stop hook)
  foo.target                     oneshot  "foo.target" that does nothing: a
                                 synchronisation point, as in systemd
  foo.mount / foo.swap           oneshot  that mounts / swapons
  foo.socket                     oneshot  that binds the sockets and parks
                                 them in an fd holder for the service
  foo.timer                      longrun  running the timer daemon
  foo.device                     oneshot  that waits for the device node

Units keep their semantics as far as s6-rc can express them.  The main
difference to bridge is that s6-rc knows one kind of dependency ("start
after, and require; restart when it restarts"), where systemd separates
ordering (After=) from requirement (Requires=, Wants=).  Two source trees are
therefore written, to be compiled into two databases of the same services:

  source-boot/   every ordering constraint is a dependency.  The machine
                 boots on this one, so services come up in the right order,
                 as parallel as the constraints allow.
  source/        only real requirements (Requires=, BindsTo=) are
                 dependencies.  The system switches to this one as soon as
                 the boot transaction is over.  With it, stopping or
                 replacing a service affects what requires it and nothing
                 else, like under systemd - in particular a configuration
                 switch does not restart half the system because a unit was
                 added somewhere early in the ordering.

Once on the second database, ordering between units that are started or
stopped together is restored by their "rank" (see index.tsv): a number that
grows along every ordering edge.

Further points:

  * After= only counts against units that are going to be started anyway
    (part of the boot transaction, or pulled in by the unit itself), like
    systemd ignores ordering against units that are not in the transaction.
  * Wants= must not make a unit fail when the wanted unit fails.  Oneshots
    that are merely wanted therefore report success to s6-rc even when they
    fail; the failure is logged and recorded for `systemctl status`.
  * systemd breaks ordering cycles at run time; s6-rc-compile rejects them.
    Cycles are broken here, weakest edge first, and reported.

Everything that was ignored or approximated ends up in report.txt.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from collections import defaultdict

SUFFIXES = (
    "service", "socket", "target", "mount", "automount", "swap",
    "timer", "path", "slice", "scope", "device",
)

# Marks a value that is only known on the running system (%H, %m, …).  The
# name between the two markers is looked up by the runtime.
RT_OPEN, RT_CLOSE = "", ""

# "system": the units of the system manager.  "user": those of a user's
# manager, where %t, %S, %h and friends name that user's directories, which
# only the runtime knows.
SCOPE = "system"


def die(msg):
    sys.stderr.write("unitc: " + msg + "\n")
    sys.exit(1)


# --------------------------------------------------------------------------
# Unit names

def split_name(name):
    """'getty@tty1.service' -> ('getty', 'tty1', 'service')."""
    base, _, suffix = name.rpartition(".")
    if not base or suffix not in SUFFIXES:
        return None
    if "@" in base:
        prefix, _, instance = base.partition("@")
        return prefix, instance, suffix
    return base, None, suffix


def is_unit_name(name):
    return split_name(name) is not None


def is_template(name):
    parts = split_name(name)
    return parts is not None and parts[1] == ""


def template_of(name):
    prefix, instance, suffix = split_name(name)
    if instance is None:
        return None
    return "%s@.%s" % (prefix, suffix)


def unescape_name(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "-":
            out.append("/")
        elif c == "\\" and s[i + 1:i + 2] == "x" and len(s) >= i + 4:
            try:
                out.append(chr(int(s[i + 2:i + 4], 16)))
                i += 3
            except ValueError:
                out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def unescape_path(s):
    p = unescape_name(s)
    return p if p.startswith("/") else "/" + p


def escape_path(path):
    path = re.sub(r"/+", "/", path).strip("/")
    if not path:
        return "-"
    out = []
    for i, c in enumerate(path):
        if c == "/":
            out.append("-")
        elif c.isalnum() or c in ":_" or (c == "." and i > 0):
            out.append(c)
        else:
            out.append("".join("\\x%02x" % b for b in c.encode()))
    return "".join(out)


# --------------------------------------------------------------------------
# Unit file syntax

def parse_unit_text(text):
    """Yield (section, key, value) in file order."""
    section = None
    pending = None
    for raw in text.split("\n"):
        stripped = raw.strip()
        if pending is None:
            if not stripped or stripped[0] in "#;":
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                section = stripped[1:-1]
                continue
            line = raw.lstrip()
        else:
            if stripped[:1] in ("#", ";"):
                continue
            line = pending + raw
        if line.endswith("\\"):
            pending = line[:-1] + " "
            continue
        pending = None
        key, sep, value = line.partition("=")
        if not sep or section is None:
            continue
        yield section, key.strip(), value.strip()


class Settings:
    """All assignments of a unit, main file first, then drop-ins."""

    def __init__(self):
        self.items = []

    def add_text(self, text):
        self.items.extend(parse_unit_text(text))

    def add(self, section, key, value):
        self.items.append((section, key, value))

    def all(self, section, key):
        """Values of a list-valued setting; an empty assignment resets it."""
        vals = []
        for s, k, v in self.items:
            if s == section and k == key:
                if v == "":
                    vals = []
                else:
                    vals.append(v)
        return vals

    def get(self, section, key, default=None):
        vals = self.all(section, key)
        return vals[-1] if vals else default

    def words(self, section, key):
        out = []
        for v in self.all(section, key):
            out.extend(v.split())
        return out

    def keys(self, section):
        return {k for s, k, _ in self.items if s == section}

    def sections(self):
        return {s for s, _, _ in self.items}


def parse_bool(v, default=False):
    if v is None:
        return default
    v = v.strip().lower()
    if v in ("1", "yes", "true", "on", "y", "t"):
        return True
    if v in ("0", "no", "false", "off", "n", "f"):
        return False
    return default


_TIME_UNITS = {
    "usec": 1e-6, "us": 1e-6, "μs": 1e-6, "µs": 1e-6,
    "msec": 1e-3, "ms": 1e-3,
    "seconds": 1, "second": 1, "sec": 1, "s": 1, "": 1,
    "minutes": 60, "minute": 60, "min": 60, "m": 60,
    "hours": 3600, "hour": 3600, "hr": 3600, "h": 3600,
    "days": 86400, "day": 86400, "d": 86400,
    "weeks": 604800, "week": 604800, "w": 604800,
    "months": 2629800, "month": 2629800, "M": 2629800,
    "years": 31557600, "year": 31557600, "y": 31557600,
}


def parse_time_ms(v, default_unit=1.0):
    """systemd time span -> milliseconds; None for infinity."""
    if v is None:
        return None
    v = v.strip()
    if v in ("infinity", ""):
        return None
    total = 0.0
    pos = 0
    found = False
    for m in re.finditer(r"\s*([0-9]*\.?[0-9]+)\s*([a-zA-Zμµ]*)", v):
        if m.start() != pos:
            raise ValueError("bad time span %r" % v)
        pos = m.end()
        unit = m.group(2)
        if unit == "":
            mult = default_unit
        elif unit in _TIME_UNITS:
            mult = _TIME_UNITS[unit]
        else:
            raise ValueError("bad time unit in %r" % v)
        total += float(m.group(1)) * mult
        found = True
    if not found or v[pos:].strip():
        raise ValueError("bad time span %r" % v)
    return int(round(total * 1000))


_SIZE_SUFFIX = {"": 1, "B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40, "P": 1 << 50, "E": 1 << 60}


def parse_size(v):
    m = re.fullmatch(r"\s*([0-9]+)\s*([BKMGTPE]?)\s*", v)
    if not m:
        raise ValueError("bad size %r" % v)
    return int(m.group(1)) * _SIZE_SUFFIX[m.group(2)]


SIGNALS = {
    "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "BUS": 7,
    "FPE": 8, "KILL": 9, "USR1": 10, "SEGV": 11, "USR2": 12, "PIPE": 13,
    "ALRM": 14, "TERM": 15, "STKFLT": 16, "CHLD": 17, "CONT": 18, "STOP": 19,
    "TSTP": 20, "TTIN": 21, "TTOU": 22, "URG": 23, "XCPU": 24, "XFSZ": 25,
    "VTALRM": 26, "PROF": 27, "WINCH": 28, "IO": 29, "PWR": 30, "SYS": 31,
}
SIGNAL_NAMES = {v: k for k, v in SIGNALS.items()}


def parse_signal(v):
    """Return the signal name without SIG prefix, or None."""
    v = v.strip().upper()
    if v.startswith("SIG"):
        v = v[3:]
    if v in SIGNALS:
        return v
    if v.startswith("RTMIN"):
        return v
    if v.isdigit() and int(v) in SIGNAL_NAMES:
        return SIGNAL_NAMES[int(v)]
    return None


EXIT_NAMES = {
    "SUCCESS": 0, "FAILURE": 1, "INVALIDARGUMENT": 2, "NOTIMPLEMENTED": 3,
    "NOPERMISSION": 4, "NOTINSTALLED": 5, "NOTCONFIGURED": 6, "NOTRUNNING": 7,
    "USAGE": 64, "DATAERR": 65, "NOINPUT": 66, "NOUSER": 67, "NOHOST": 68,
    "UNAVAILABLE": 69, "SOFTWARE": 70, "OSERR": 71, "OSFILE": 72,
    "CANTCREAT": 73, "IOERR": 74, "TEMPFAIL": 75, "PROTOCOL": 76,
    "NOPERM": 77, "CONFIG": 78,
}


def parse_status_set(words):
    codes, signals = [], []
    for w in words:
        if w.isdigit():
            codes.append(int(w))
        elif w.upper() in EXIT_NAMES:
            codes.append(EXIT_NAMES[w.upper()])
        else:
            sig = parse_signal(w)
            if sig:
                signals.append(sig)
    return codes, signals


# --------------------------------------------------------------------------
# Word splitting, as systemd does it for Exec*= and Environment=

_C_ESCAPES = {
    "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t",
    "v": "\v", "\\": "\\", '"': '"', "'": "'", "s": " ",
}


def _unescape_at(s, i):
    """s[i] is a backslash.  Return (text, next index)."""
    nxt = s[i + 1:i + 2]
    if nxt == "":
        return "\\", i + 1
    if nxt in _C_ESCAPES:
        return _C_ESCAPES[nxt], i + 2
    if nxt == "x" and re.fullmatch(r"[0-9a-fA-F]{2}", s[i + 2:i + 4] or ""):
        return chr(int(s[i + 2:i + 4], 16)), i + 4
    if nxt == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", s[i + 2:i + 6] or ""):
        return chr(int(s[i + 2:i + 6], 16)), i + 6
    if nxt == "U" and re.fullmatch(r"[0-9a-fA-F]{8}", s[i + 2:i + 10] or ""):
        return chr(int(s[i + 2:i + 10], 16)), i + 10
    if re.fullmatch(r"[0-7]{3}", s[i + 1:i + 4] or ""):
        return chr(int(s[i + 1:i + 4], 8)), i + 4
    # Unknown escape: keep it verbatim (systemd warns and does the same).
    return "\\" + nxt, i + 2


def split_words(s, unescape=True):
    """Split a line into words, honouring quotes and C escapes.

    Returns a list of (word, was_quoted)."""
    words = []
    cur = []
    quoted = False
    in_word = False
    quote = None
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if quote:
            if c == quote:
                quote = None
                i += 1
            elif c == "\\" and unescape:
                text, i = _unescape_at(s, i)
                cur.append(text)
            else:
                cur.append(c)
                i += 1
            continue
        if c in " \t\n":
            if in_word:
                words.append(("".join(cur), quoted))
                cur, quoted, in_word = [], False, False
            i += 1
            continue
        # (in the middle of a word too: `-port="8888"` is -port=8888, as
        # systemd's extract_first_word() has it, and nixpkgs' cfssl relies on)
        if c in "\"'":
            quote = c
            quoted = True
            in_word = True
            i += 1
            continue
        if c == "\\" and unescape:
            text, i = _unescape_at(s, i)
            cur.append(text)
            in_word = True
            continue
        cur.append(c)
        in_word = True
        i += 1
    if in_word:
        words.append(("".join(cur), quoted))
    return words


# --------------------------------------------------------------------------
# Shell output

def sq(s):
    """Quote for bash, turning runtime markers into variable references."""
    s = str(s)
    if RT_OPEN not in s:
        return "'" + s.replace("'", "'\\''") + "'"
    out = []
    for part in re.split("(%s[^%s]*%s)" % (RT_OPEN, RT_CLOSE, RT_CLOSE), s):
        if part.startswith(RT_OPEN):
            out.append('"${__u_spec_%s}"' % part[1:-1])
        elif part:
            out.append("'" + part.replace("'", "'\\''") + "'")
    return "".join(out) or "''"


def sh_array(name, values):
    return "%s=(%s)" % (name, " ".join(sq(v) for v in values))


_ENV_NAME = r"[A-Za-z_][A-Za-z0-9_]*"


def exec_arg_to_shell(word, expand_env):
    """One word of an Exec line -> bash source producing the argument(s)."""
    if not expand_env:
        return sq(word)
    if re.fullmatch(r"\$" + _ENV_NAME, word):
        # A whole word "$FOO": split at whitespace into zero or more words.
        return "${%s-}" % word[1:]
    out = []
    pos = 0
    for m in re.finditer(r"\$\$|\$\{(%s)\}" % _ENV_NAME, word):
        if m.start() > pos:
            out.append(sq(word[pos:m.start()]))
        if m.group(0) == "$$":
            out.append(sq("$"))
        else:
            out.append('"${%s-}"' % m.group(1))
        pos = m.end()
    if pos < len(word):
        out.append(sq(word[pos:]))
    return "".join(out) or "''"


# --------------------------------------------------------------------------
# Loading units

class Unit:
    def __init__(self, name):
        self.name = name
        self.prefix, self.instance, self.kind = split_name(name)
        self.settings = Settings()
        self.masked = False
        self.has_file = False
        self.source_text = ""
        # dependency sets, filled in by the graph builder
        self.requires = set()
        self.wants = set()
        self.binds_to = set()
        self.after = set()
        self.before = set()
        self.weak_after = set()   # After= that only stems from default dependencies
        self.conflicts = set()
        self.atoms = []           # s6-rc atomic services making up this unit
        self.ready = []           # atoms a dependent has to wait for

    @property
    def atom(self):
        # X-S6-Name= picks the name on the s6 side; the unit keeps its own.
        custom = self.settings.get("Unit", "X-S6-Name")
        if custom:
            return custom
        if self.kind == "service":
            return self.name[: -len(".service")]
        return self.name

    def get(self, key, default=None, section=None):
        return self.settings.get(section or SECTION[self.kind], key, default)

    def all(self, key, section=None):
        return self.settings.all(section or SECTION[self.kind], key)

    def words(self, key, section=None):
        return self.settings.words(section or SECTION[self.kind], key)

    def uget(self, key, default=None):
        return self.settings.get("Unit", key, default)

    def uwords(self, key):
        words = self.settings.words("Unit", key)
        # A template named without an instance by an instance of a template
        # is that same instance of it, as with systemd:
        # gnome-session@gnome.target's Requires=gnome-session-manager@.service
        # is gnome-session-manager@gnome.service.
        if self.instance:
            words = [
                "%s@%s%s" % (w[: w.index("@.")], self.instance, w[w.index("@.") + 1:])
                if is_unit_name(w) and is_template(w) else w
                for w in words
            ]
        return words


SECTION = {
    "service": "Service", "socket": "Socket", "target": "Unit", "mount": "Mount",
    "automount": "Automount", "swap": "Swap", "timer": "Timer", "path": "Path",
    "slice": "Slice", "scope": "Scope", "device": "Unit",
}


class Loader:
    def __init__(self, unit_dir, report):
        self.dir = unit_dir
        self.report = report
        self.entries = set(os.listdir(unit_dir))
        self.cache = {}
        self.aliases = {}
        for e in sorted(self.entries):
            if not is_unit_name(e):
                continue
            path = os.path.join(unit_dir, e)
            if os.path.islink(path):
                target = os.readlink(path)
                if "/" not in target and target != e and is_unit_name(target):
                    self.aliases[e] = target
        # every other name of a unit: what is linked into the .wants directory
        # of any of them, or dropped in beside any of them, is the unit's
        self.alias_names = {}
        for a in self.aliases:
            self.alias_names.setdefault(self.canonical(a), []).append(a)

    def canonical(self, name):
        seen = set()
        while name in self.aliases and name not in seen:
            seen.add(name)
            name = self.aliases[name]
        # an alias of a template covers its instances too
        parts = split_name(name)
        if parts and parts[1]:
            tmpl = template_of(name)
            if tmpl in self.aliases:
                real = split_name(self.canonical(tmpl))
                name = "%s@%s.%s" % (real[0], parts[1], real[2])
        return name

    def names(self):
        """Concrete (non-template, non-alias) unit names present in the directory.

        Device units have no file of their own; one exists as soon as
        something is linked into its .wants directory."""
        found = {
            e for e in self.entries
            if is_unit_name(e) and not is_template(e) and e not in self.aliases
        }
        for e in self.entries:
            for suffix in (".device.wants", ".device.requires"):
                if e.endswith(suffix):
                    found.add(e[: -len(suffix)] + ".device")
            # an instance of a template with drop-ins of its own: one that is
            # started by name at run time, so nothing else names it
            # (gnome-session@gnome.target, which gnome-session asks for)
            if e.endswith(".d") and is_unit_name(e[:-2]) and not is_template(e[:-2]):
                tmpl = template_of(e[:-2])
                if tmpl and tmpl in self.entries:
                    found.add(e[:-2])
        return sorted(found)

    def _read(self, name):
        path = os.path.join(self.dir, name)
        if not os.path.lexists(path):
            return None
        real = os.path.realpath(path)
        if real == "/dev/null":
            return ""
        if os.path.isdir(real):
            return None
        with open(real, encoding="utf-8", errors="replace") as f:
            return f.read()

    def _dropins(self, name):
        d = os.path.join(self.dir, name + ".d")
        out = []
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".conf"):
                    with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                        out.append(fh.read())
        return out

    def load(self, name):
        name = self.canonical(name)
        if name in self.cache:
            return self.cache[name]
        if not is_unit_name(name) or is_template(name):
            self.cache[name] = None
            return None
        u = Unit(name)
        texts = []
        main = self._read(name)
        tmpl = template_of(name)
        if main is None and tmpl:
            main = self._read(tmpl)
        if main is not None:
            u.has_file = True
            if main == "":
                path = os.path.join(self.dir, name)
                if os.path.realpath(path) == "/dev/null":
                    u.masked = True
            texts.append(main)
        # (default.target is an alias: `wantedBy = [ "default.target" ]`
        # lands in default.target.wants)
        own_names = [name] + sorted(self.alias_names.get(name, []))
        tmpl_names = ([tmpl] + sorted(self.alias_names.get(tmpl, []))) if tmpl else []
        for n in tmpl_names + own_names:
            texts.extend(self._dropins(n))
        if not texts and u.kind != "device":
            self.cache[name] = None
            return None
        # X-Replace=yes in a drop-in: this is the whole definition, whatever a
        # package may ship under the same name is not wanted.
        for i in range(len(texts) - 1, 0, -1):
            if any(sec == "Unit" and key == "X-Replace" and parse_bool(val)
                   for sec, key, val in parse_unit_text(texts[i])):
                texts = texts[i:]
                break
        for t in texts:
            u.settings.add_text(t)
        u.source_text = "\n".join(texts)
        for kind, key in ((".wants", "Wants"), (".requires", "Requires"), (".upholds", "Wants")):
            for owner in tmpl_names + own_names:
                d = os.path.join(self.dir, owner + kind)
                if os.path.isdir(d):
                    for e in sorted(os.listdir(d)):
                        if os.path.realpath(os.path.join(d, e)) == "/dev/null":
                            continue
                        u.settings.add("Unit", key, e)
        self.cache[name] = u
        return u


# --------------------------------------------------------------------------
# Specifiers

def expand_specifiers(u, s, report=None):
    if "%" not in s:
        return s
    prefix, instance, _ = u.prefix, u.instance or "", u.kind
    table = {
        "n": u.name,
        "N": u.name.rsplit(".", 1)[0],
        "p": prefix,
        "P": unescape_name(prefix),
        "i": instance,
        "I": unescape_name(instance),
        "j": prefix.rsplit("-", 1)[-1],
        "J": unescape_name(prefix.rsplit("-", 1)[-1]),
        "f": unescape_path(instance or prefix),
        "t": "/run",
        "S": "/var/lib",
        "C": "/var/cache",
        "L": "/var/log",
        "E": "/etc",
        "T": "/tmp",
        "V": "/var/tmp",
        "h": "/root",
        "u": "root",
        "U": "0",
        "g": "root",
        "G": "0",
        "s": "/bin/sh",
        "%": "%",
    }
    # (d: the credentials directory, /run/credentials/<unit> or the user's)
    runtime = {"H": "H", "l": "l", "m": "m", "b": "b", "v": "v", "a": "a", "o": "o", "w": "w", "q": "q", "d": "d"}
    if SCOPE == "user":
        for k in "tSCLEhuUgG":
            del table[k]
            runtime[k] = k
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "%" and i + 1 < len(s):
            k = s[i + 1]
            if k in table:
                out.append(table[k])
                i += 2
                continue
            if k in runtime:
                out.append(RT_OPEN + runtime[k] + RT_CLOSE)
                i += 2
                continue
            if report is not None:
                report.add(u.name, "specifier", "unknown specifier %%%s left as is" % k)
        out.append(c)
        i += 1
    return "".join(out)


# --------------------------------------------------------------------------
# Report

class Report:
    def __init__(self):
        self.items = defaultdict(list)

    def add(self, unit, kind, msg):
        entry = (kind, msg)
        if entry not in self.items[unit]:
            self.items[unit].append(entry)

    def text(self):
        lines = []
        for unit in sorted(self.items):
            lines.append(unit)
            for kind, msg in self.items[unit]:
                lines.append("  [%s] %s" % (kind, msg))
        return "\n".join(lines) + ("\n" if lines else "")


# --------------------------------------------------------------------------
# Exec lines

class ExecCmd:
    def __init__(self):
        self.argv = []          # list of words
        self.ignore_failure = False   # "-"
        self.no_env = False     # ":"
        self.privileged = False  # "+" / "!"
        self.argv0 = None       # "@"


def parse_exec(u, value, report):
    """One Exec*= value -> list of ExecCmd."""
    cmds = []
    cur = []
    for word, quoted in split_words(value):
        if word == ";" and not quoted:
            if cur:
                cmds.append(cur)
            cur = []
            continue
        if word == "\\;" and not quoted:
            word = ";"
        cur.append(word)
    if cur:
        cmds.append(cur)
    out = []
    for words in cmds:
        c = ExecCmd()
        first = words[0]
        at = False
        while first and first[0] in "-@:+!|":
            f = first[0]
            if f == "-":
                c.ignore_failure = True
            elif f == "@":
                at = True
            elif f == ":":
                c.no_env = True
            elif f in "+!":
                c.privileged = True
            first = first[1:]
        rest = words[1:]
        if not first:
            continue
        if at:
            if not rest:
                report.add(u.name, "exec", "'@' prefix without an argv[0] in %r" % value)
            else:
                c.argv0 = expand_specifiers(u, rest[0], report)
                rest = rest[1:]
        c.argv = [expand_specifiers(u, w, report) for w in [first] + rest]
        out.append(c)
    return out


def emit_exec_list(u, lines, fname, key, section, report):
    cmds = []
    for value in u.settings.all(section, key):
        cmds.extend(parse_exec(u, value, report))
    lines.append("U_N_%s=%d" % (fname.upper(), len(cmds)))
    for i, c in enumerate(cmds):
        args = " ".join(exec_arg_to_shell(a, not c.no_env) for a in c.argv)
        flags = ("-" if c.ignore_failure else "") + ("+" if c.privileged else "")
        lines.append(
            "u_%s_%d() { __u_flags=%s; __u_argv0=%s; __u_argv=( %s ); }"
            % (fname, i, sq(flags), sq(c.argv0 or ""), args)
        )
    return cmds


# --------------------------------------------------------------------------
# Per-kind data files

# Directives that are understood but deliberately have no effect here.
IGNORED_QUIETLY = {
    "Service": {
        "Slice", "Delegate", "DelegateSubgroup", "WatchdogSec", "NotifyAccess",
        "FileDescriptorStoreMax", "FileDescriptorStorePreserve", "IOAccounting",
        "CPUAccounting", "MemoryAccounting", "TasksAccounting", "IPAccounting",
        "BlockIOAccounting", "SyslogIdentifier", "SyslogFacility", "SyslogLevel",
        "SyslogLevelPrefix", "LogLevelMax", "LogExtraFields", "LogRateLimitIntervalSec",
        "LogRateLimitBurst", "LogNamespace", "GuessMainPID", "USBFunctionDescriptors",
        "USBFunctionStrings", "X-RestartIfChanged", "X-ReloadIfChanged",
        "X-StopIfChanged", "X-NotSocketActivated", "X-OnlyManualStart",
        "ExecSearchPath", "TTYVTDisallocate",
        "IgnoreSIGPIPE", "UtmpIdentifier", "UtmpMode",
        "KeyringMode", "Personality", "RuntimeMaxSec", "TimeoutAbortSec",
        "WatchdogSignal", "ManagedOOMSwap", "ManagedOOMMemoryPressure",
        "ManagedOOMMemoryPressureLimit", "ManagedOOMPreference", "OOMPolicy",
        "ImportCredential", "RestartSteps", "RestartMaxDelaySec", "RestartMode",
        "CoredumpFilter", "ExitType", "DefaultDependencies",
        "FileDescriptorName", "Sockets", "CPUSchedulingResetOnFork",
        "MemoryDenyWriteExecute", "LockPersonality",
    },
}

# Sandboxing and hardening.  Services run without them; listed in the report.
SANDBOX_KEYS = {
    "PrivateTmp", "PrivateDevices", "PrivateNetwork", "PrivateUsers", "PrivateMounts",
    "PrivateIPC", "PrivatePIDs", "ProtectSystem", "ProtectHome", "ProtectKernelTunables",
    "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups", "ProtectClock",
    "ProtectHostname", "ProtectProc", "ProcSubset", "ReadWritePaths", "ReadOnlyPaths",
    "InaccessiblePaths", "ExecPaths", "NoExecPaths", "BindPaths", "BindReadOnlyPaths",
    "TemporaryFileSystem", "RestrictAddressFamilies", "RestrictNamespaces",
    "RestrictRealtime", "RestrictSUIDSGID", "RemoveIPC", "SystemCallFilter",
    "SystemCallArchitectures", "SystemCallErrorNumber", "SystemCallLog",
    "IPAddressAllow", "IPAddressDeny", "DeviceAllow", "DevicePolicy",
    "RootImage", "RootDirectoryStartOnly", "MountFlags", "MountAPIVFS",
    "NetworkNamespacePath", "IPCNamespacePath", "SocketBindAllow", "SocketBindDeny",
    "RestrictNetworkInterfaces", "RestrictFileSystems", "SELinuxContext",
    "AppArmorProfile", "SmackProcessLabel", "SecureBits", "ProtectKernelTunables",
    "UMask_",
}

LIMITS = {
    "LimitCPU": "cpu", "LimitFSIZE": "fsize", "LimitDATA": "data", "LimitSTACK": "stack",
    "LimitCORE": "core", "LimitRSS": "rss", "LimitNOFILE": "nofile", "LimitAS": "as",
    "LimitNPROC": "nproc", "LimitMEMLOCK": "memlock", "LimitLOCKS": "locks",
    "LimitSIGPENDING": "sigpending", "LimitMSGQUEUE": "msgqueue", "LimitNICE": "nice",
    "LimitRTPRIO": "rtprio", "LimitRTTIME": "rttime",
}

CGROUP_KEYS = {
    "MemoryMax": "memory.max", "MemoryHigh": "memory.high", "MemoryLow": "memory.low",
    "MemoryMin": "memory.min", "MemorySwapMax": "memory.swap.max", "TasksMax": "pids.max",
    "CPUWeight": "cpu.weight", "IOWeight": "io.weight", "AllowedCPUs": "cpuset.cpus",
    "AllowedMemoryNodes": "cpuset.mems", "CPUQuota": "cpu.max",
    "MemoryLimit": "memory.max",
}

CONDITIONS = (
    "PathExists", "PathExistsGlob", "PathIsDirectory", "PathIsSymbolicLink",
    "PathIsMountPoint", "PathIsReadWrite", "DirectoryNotEmpty", "FileNotEmpty",
    "FileIsExecutable", "KernelCommandLine", "Virtualization", "Capability",
    "ACPower", "FirstBoot", "NeedsUpdate", "User", "Group", "Host",
    "Architecture", "KernelVersion", "Security", "Environment", "Credential",
    "ControlGroupController", "Memory", "CPUs", "PathIsEncrypted",
    "MemoryPressure", "CPUPressure", "IOPressure", "OSRelease", "Firmware",
    "CPUFeature", "KernelModuleLoaded", "Version",
)


def emit_conditions(u, lines):
    conds, asserts = [], []
    for name in CONDITIONS:
        for prefix, dest in (("Condition", conds), ("Assert", asserts)):
            for v in u.settings.all("Unit", prefix + name):
                trigger = "0"
                negate = "0"
                if v.startswith("|"):
                    trigger, v = "1", v[1:]
                if v.startswith("!"):
                    negate, v = "1", v[1:]
                dest.append("\x1f".join((name, trigger, negate, expand_specifiers(u, v))))
    lines.append(sh_array("U_CONDITIONS", conds))
    lines.append(sh_array("U_ASSERTS", asserts))


def cgroup_value(key, v, report, unit):
    v = v.strip()
    if v == "infinity":
        return "max"
    try:
        if key == "CPUQuota":
            pct = float(v.rstrip("%"))
            return "%d 100000" % int(pct * 1000)
        if key in ("CPUWeight", "IOWeight", "AllowedCPUs", "AllowedMemoryNodes"):
            return v
        if v.endswith("%"):
            float(v[:-1])
            return v            # a share of RAM / of the pid limit; resolved at run time
        if key == "TasksMax":
            return str(int(v))
        return str(parse_size(v))
    except ValueError:
        report.add(unit, "resource", "cannot parse %s=%s" % (key, v))
        return None


def caps_to_setpriv(words, bounding):
    invert = False
    names = []
    for w in words:
        if w.startswith("~"):
            invert = True
            w = w[1:]
        if not w:
            continue
        w = w.lower()
        if w.startswith("cap_"):
            w = w[4:]
        names.append(w)
    if bounding:
        if invert:
            return ",".join("-" + n for n in names)
        return ",".join(["-all"] + ["+" + n for n in names])
    if invert:
        return ",".join(["+all"] + ["-" + n for n in names])
    return ",".join("+" + n for n in names)


# Sandboxing directives that are applied (by unit-sandbox, or as dropped
# capabilities).  The rest of SANDBOX_KEYS stays in the report.
SANDBOX_APPLIED = {
    "PrivateTmp", "PrivateDevices", "PrivateNetwork", "PrivateMounts", "PrivateIPC",
    "ProtectSystem", "ProtectHome", "ProtectKernelTunables", "ProtectKernelModules",
    "ProtectKernelLogs", "ProtectControlGroups", "ProtectClock", "ProtectHostname",
    "ReadWritePaths", "ReadOnlyPaths", "InaccessiblePaths", "BindPaths",
    "BindReadOnlyPaths", "TemporaryFileSystem", "MountAPIVFS", "RootDirectoryStartOnly",
}


def sandbox_settings(u, section, report):
    """The arguments of unit-sandbox for one unit, and the capabilities its
    settings take away.  (DynamicUser= implies a good part of it.)"""
    s = u.settings
    g = lambda k, d=None: s.get(section, k, d)
    args = []
    drops = []
    dyn = parse_bool(g("DynamicUser"))

    def on(key):
        return bool(parse_bool(g(key)))

    root = expand_specifiers(u, g("RootDirectory", "") or "", report)
    if root:
        args += ["--root", root]
        # (on unless said otherwise, with a root of its own: systemd's
        # exec_context_get_effective_mount_apivfs(); wpa_supplicant's start
        # script needs /proc for its /dev/fd)
        if parse_bool(g("MountAPIVFS"), True):
            args.append("--api-vfs")
    if on("PrivateTmp") or dyn:
        args.append("--private-tmp")
    if on("PrivateDevices"):
        args.append("--private-devices")
    if on("PrivateNetwork"):
        args.append("--private-network")
    if on("PrivateIPC"):
        args.append("--private-ipc")
    if on("ProtectHostname"):
        args.append("--private-uts")

    ps = (g("ProtectSystem") or "").strip().lower()
    if ps in ("yes", "true", "1", "on"):
        ps = "yes"
    elif ps in ("full", "strict"):
        pass
    elif dyn and ps not in ("no", "false", "0", "off"):
        ps = "strict"
    else:
        ps = ""
    if ps:
        args += ["--protect-system", ps]
    # systemd 260 leaves /run writable under ProtectSystem=strict when
    # ProtectProc= or ProcSubset= is set as well (it remounts differently
    # then); nginx relies on it (nixpkgs' nginx-tmpdir test writes in /run)
    pp = (g("ProtectProc") or "default").strip().lower()
    if ps == "strict" and (pp != "default" or (g("ProcSubset") or "").strip().lower() == "pid"):
        args.append("--strict-run-writable")

    ph = (g("ProtectHome") or "").strip().lower()
    if ph in ("yes", "true", "1", "on"):
        ph = "yes"
    elif ph in ("read-only", "tmpfs"):
        pass
    elif dyn and ph not in ("no", "false", "0", "off"):
        ph = "read-only"
    else:
        ph = ""
    if ph:
        args += ["--protect-home", ph]

    if on("ProtectKernelTunables"):
        args.append("--kernel-tunables")
    if on("ProtectControlGroups"):
        args.append("--cgroups")
    if on("ProtectKernelModules"):
        drops.append("sys_module")
    if on("ProtectKernelLogs"):
        drops.append("syslog")
        args += ["--inaccessible", "-/proc/kmsg", "--inaccessible", "-/dev/kmsg"]
    if on("ProtectClock"):
        drops += ["sys_time", "wake_alarm"]

    for key, flag in (
        ("ReadOnlyPaths", "--read-only"),
        ("ReadWritePaths", "--read-write"),
        ("InaccessiblePaths", "--inaccessible"),
        ("BindPaths", "--bind"),
        ("BindReadOnlyPaths", "--bind-ro"),
        ("TemporaryFileSystem", "--tmpfs"),
    ):
        for w in s.words(section, key):
            w = expand_specifiers(u, w, report)
            if flag == "--bind-ro":
                parts = w.split(":")
                src = parts[0]
                dst = parts[1] if len(parts) > 1 and parts[1] else src.lstrip("-")
                opts = (parts[2] + ",ro") if len(parts) > 2 and parts[2] else "ro"
                args += ["--bind", "%s:%s:%s" % (src, dst, opts)]
            else:
                args += [flag, w]

    # what the unit is given to write in stays writable under ProtectSystem=
    # and the like; without any of them there is no sandbox to speak of, and
    # these must not make one
    restricts = [
        a for a in args
        if a in ("--protect-system", "--protect-home", "--read-only", "--inaccessible",
                 "--tmpfs", "--kernel-tunables", "--cgroups")
    ]
    directories = (
        ("RuntimeDirectory", "/run"), ("StateDirectory", "/var/lib"),
        ("CacheDirectory", "/var/cache"), ("LogsDirectory", "/var/log"),
        ("ConfigurationDirectory", "/etc"),
    )
    # a root directory of its own has none of them: they are bound into it,
    # at the places they have outside
    if root:
        for key, base in directories:
            for w in s.words(section, key):
                d = expand_specifiers(u, w.split(":")[0], report)
                if d:
                    p = "%s/%s" % (base, d)
                    args += ["--bind", "-%s:%s" % (p, p)]
    for key, base in directories:
        for w in (s.words(section, key) if restricts else []):
            d = expand_specifiers(u, w.split(":")[0], report)
            if d:
                args += ["--read-write", "-%s/%s" % (base, d)]

    if not args and not drops and not on("PrivateMounts"):
        return [], []
    if not args and on("PrivateMounts"):
        # a mount namespace and nothing else: mounts of the service stay its own
        args.append("--private-mounts")
    return args, drops



def emit_exec_context(u, section, lines, report):
    """Settings shared by everything that runs processes (systemd.exec(5))."""
    s = u.settings
    g = lambda k, d=None: s.get(section, k, d)

    # Environment
    env_lines = []
    for v in s.all(section, "Environment"):
        for word, _ in split_words(v):
            name, sep, val = word.partition("=")
            if sep and re.fullmatch(_ENV_NAME, name):
                env_lines.append("export %s=%s" % (name, sq(expand_specifiers(u, val, report))))
    lines.append("u_env() { %s; }" % "; ".join(env_lines or [":"]))
    lines.append(sh_array("U_ENV_FILES", [expand_specifiers(u, w) for w in s.words(section, "EnvironmentFile")]))
    lines.append(sh_array("U_UNSET_ENV", s.words(section, "UnsetEnvironment")))
    lines.append(sh_array("U_PASS_ENV", s.words(section, "PassEnvironment")))

    lines.append("U_USER=%s" % sq(expand_specifiers(u, g("User", ""))))
    lines.append("U_GROUP=%s" % sq(expand_specifiers(u, g("Group", ""))))
    lines.append(sh_array("U_SUPP_GROUPS", s.words(section, "SupplementaryGroups")))
    lines.append("U_DYNAMIC_USER=%d" % parse_bool(g("DynamicUser")))

    wd = expand_specifiers(u, g("WorkingDirectory", ""))
    lines.append("U_WORKDIR_OPTIONAL=%d" % wd.startswith("-"))
    lines.append("U_WORKDIR=%s" % sq(wd.lstrip("-")))
    lines.append("U_ROOTDIR=%s" % sq(expand_specifiers(u, g("RootDirectory", ""))))
    lines.append("U_ROOT_START_ONLY=%d" % parse_bool(g("RootDirectoryStartOnly")))
    lines.append("U_UMASK=%s" % sq(g("UMask", "")))
    lines.append("U_NICE=%s" % sq(g("Nice", "")))
    lines.append("U_OOM_ADJ=%s" % sq(g("OOMScoreAdjust", "")))
    lines.append("U_IOSCHED_CLASS=%s" % sq(g("IOSchedulingClass", "")))
    lines.append("U_IOSCHED_PRIO=%s" % sq(g("IOSchedulingPriority", "")))
    lines.append("U_CPUSCHED_POLICY=%s" % sq(g("CPUSchedulingPolicy", "")))
    lines.append("U_CPUSCHED_PRIO=%s" % sq(g("CPUSchedulingPriority", "")))
    lines.append("U_CPU_AFFINITY=%s" % sq(" ".join(s.words(section, "CPUAffinity"))))

    limits = []
    for key, name in LIMITS.items():
        v = g(key)
        if v is None:
            continue
        parts = v.split(":")
        try:
            conv = []
            for p in parts:
                p = p.strip()
                if p == "infinity":
                    conv.append("unlimited")
                elif key in ("LimitCPU",):
                    conv.append(str(int((parse_time_ms(p) or 0) / 1000)))
                elif key in ("LimitRTTIME",):
                    conv.append(str((parse_time_ms(p, 1e-6) or 0) * 1000))
                elif key in ("LimitNICE",):
                    conv.append(p.lstrip("+"))
                else:
                    conv.append(str(parse_size(p)))
            limits.append("--%s=%s" % (name, ":".join(conv)))
        except ValueError:
            report.add(u.name, "resource", "cannot parse %s=%s" % (key, v))
    lines.append(sh_array("U_LIMITS", limits))

    amb = s.words(section, "AmbientCapabilities")
    bnd = s.words(section, "CapabilityBoundingSet")
    sandbox_args, cap_drops = sandbox_settings(u, section, report)
    lines.append("U_CAP_AMBIENT=%s" % sq(caps_to_setpriv(amb, False) if amb else ""))
    if bnd:
        cap_bound = caps_to_setpriv(bnd, True)
    elif "CapabilityBoundingSet" in s.keys(section):
        cap_bound = "-all"      # explicitly emptied
    else:
        cap_bound = ""
    if cap_drops:
        if cap_bound.startswith("-all"):
            # an allow list: take them out of it
            cap_bound = ",".join(t for t in cap_bound.split(",") if t.lstrip("+") not in cap_drops)
        else:
            cap_bound = ",".join([t for t in cap_bound.split(",") if t] + ["-" + c for c in cap_drops])
    lines.append("U_CAP_BOUND=%s" % sq(cap_bound))
    lines.append(sh_array("U_SANDBOX", sandbox_args))
    lines.append("U_NNP=%d" % parse_bool(g("NoNewPrivileges")))

    lines.append("U_STDIN=%s" % sq(g("StandardInput", "null")))
    lines.append("U_STDOUT=%s" % sq(expand_specifiers(u, g("StandardOutput", "journal"))))
    lines.append("U_STDERR=%s" % sq(expand_specifiers(u, g("StandardError", "inherit"))))
    lines.append("U_TTY=%s" % sq(expand_specifiers(u, g("TTYPath", "/dev/console"))))
    # (unit-tty: what is done to the terminal before it is the service's)
    lines.append("U_TTY_HANGUP=%d" % parse_bool(g("TTYVHangup")))
    lines.append("U_TTY_RESET=%d" % parse_bool(g("TTYReset")))
    # (a getty of tty2 and up: started when its console is switched to, as
    # logind's autovt would; see unit-vt-wait)
    lines.append("U_VT_WAIT=%d" % parse_bool(g("X-WaitForVT")))
    # a PAM session around the command (unit-pam)
    lines.append("U_PAM_NAME=%s" % sq(g("PAMName", "")))

    for key, var in (
        ("RuntimeDirectory", "RUNTIME"), ("StateDirectory", "STATE"),
        ("CacheDirectory", "CACHE"), ("LogsDirectory", "LOGS"),
        ("ConfigurationDirectory", "CONF"),
    ):
        dirs = [expand_specifiers(u, w.split(":")[0]) for w in s.words(section, key)]
        lines.append(sh_array("U_%s_DIRS" % var, dirs))
        lines.append("U_%s_DIR_MODE=%s" % (var, sq(g(key + "Mode", "0755"))))
    lines.append("U_RUNTIME_PRESERVE=%s" % sq(g("RuntimeDirectoryPreserve", "no")))

    creds = []
    for key in ("LoadCredential", "LoadCredentialEncrypted"):
        for v in s.all(section, key):
            cid, sep, path = v.partition(":")
            creds.append("%s\x1f%s" % (cid, expand_specifiers(u, path) if sep else ""))
    lines.append(sh_array("U_CREDS", creds))
    set_creds = []
    for v in s.all(section, "SetCredential"):
        cid, sep, val = v.partition(":")
        if sep:
            set_creds.append("%s\x1f%s" % (cid, val))
    lines.append(sh_array("U_SET_CREDS", set_creds))

    cg = []
    for key, fname in CGROUP_KEYS.items():
        v = g(key)
        if v is None:
            continue
        val = cgroup_value(key, v, report, u.name)
        if val is not None:
            cg.append("%s\x1f%s" % (fname, val))
    lines.append(sh_array("U_CGROUP_SET", cg))

    sandbox = sorted(k for k in s.keys(section) if k in SANDBOX_KEYS and k not in SANDBOX_APPLIED)
    if sandbox:
        report.add(u.name, "sandbox", "not applied: " + " ".join(sandbox))
    lines.append("U_KILL_MODE=%s" % sq(g("KillMode", "control-group")))
    lines.append("U_KILL_SIGNAL=%s" % sq(parse_signal(g("KillSignal", "TERM")) or "TERM"))
    lines.append("U_SEND_SIGKILL=%d" % parse_bool(g("SendSIGKILL"), True))
    lines.append("U_SEND_SIGHUP=%d" % parse_bool(g("SendSIGHUP"), False))


SERVICE_KEYS_HANDLED = {
    "Type", "RemainAfterExit", "ExecStart", "ExecStartPre", "ExecStartPost",
    "ExecStop", "ExecStopPost", "ExecReload", "ExecCondition", "Restart",
    "RestartSec", "SuccessExitStatus", "RestartPreventExitStatus",
    "RestartForceExitStatus", "TimeoutSec", "TimeoutStartSec", "TimeoutStopSec",
    "PIDFile", "BusName", "Environment", "EnvironmentFile", "UnsetEnvironment",
    "PassEnvironment", "User", "Group", "SupplementaryGroups", "DynamicUser",
    "WorkingDirectory", "RootDirectory", "UMask", "Nice", "OOMScoreAdjust",
    "IOSchedulingClass", "IOSchedulingPriority", "CPUSchedulingPolicy",
    "CPUSchedulingPriority", "CPUAffinity", "AmbientCapabilities",
    "CapabilityBoundingSet", "NoNewPrivileges", "StandardInput", "StandardOutput",
    "StandardError", "TTYPath", "RuntimeDirectory", "RuntimeDirectoryMode",
    "RuntimeDirectoryPreserve", "StateDirectory", "StateDirectoryMode",
    "CacheDirectory", "CacheDirectoryMode", "LogsDirectory", "LogsDirectoryMode",
    "ConfigurationDirectory", "ConfigurationDirectoryMode", "LoadCredential",
    "LoadCredentialEncrypted", "SetCredential", "KillMode", "KillSignal",
    "SendSIGKILL", "SendSIGHUP", "PermissionsStartOnly", "NonBlocking",
    "X-NotifyFd", "X-WaitForVT", "ReloadSignal", "PAMName",
} | set(LIMITS) | set(CGROUP_KEYS)


def service_type(u):
    t = u.get("Type")
    if t:
        return t
    if u.get("BusName"):
        return "dbus"
    if not u.all("ExecStart"):
        return "oneshot"
    return "simple"


def timeouts(u):
    """(start_ms, stop_ms); 0 means no limit."""
    typ = service_type(u)
    both = u.get("TimeoutSec")
    start = u.get("TimeoutStartSec", both)
    stop = u.get("TimeoutStopSec", both)
    try:
        start_ms = (parse_time_ms(start) or 0) if start is not None else (0 if typ == "oneshot" else 90000)
    except ValueError:
        start_ms = 90000
    try:
        stop_ms = (parse_time_ms(stop) or 0) if stop is not None else 90000
    except ValueError:
        stop_ms = 90000
    return start_ms, stop_ms


def emit_common(u, lines):
    lines.append("U_SCOPE=%s" % sq(SCOPE))
    lines.append("U_UNIT=%s" % sq(u.name))
    lines.append("U_ATOM=%s" % sq(u.atom))
    lines.append("U_KIND=%s" % sq(u.kind))
    lines.append("U_DESCRIPTION=%s" % sq(expand_specifiers(u, u.uget("Description", u.name))))
    emit_conditions(u, lines)
    lines.append(sh_array("U_ON_FAILURE", u.uwords("OnFailure")))
    lines.append(sh_array("U_ON_SUCCESS", u.uwords("OnSuccess")))


def emit_service(u, ctx):
    report = ctx.report
    lines = []
    emit_common(u, lines)
    typ = service_type(u)
    known_types = ("simple", "exec", "forking", "oneshot", "dbus", "notify", "notify-reload", "idle")
    if typ not in known_types:
        report.add(u.name, "type", "unknown Type=%s, treated as simple" % typ)
        typ = "simple"
    lines.append("U_TYPE=%s" % sq(typ))
    lines.append("U_REMAIN=%d" % parse_bool(u.get("RemainAfterExit")))
    lines.append("U_HARD_FAIL=%d" % (u.name in ctx.required_units))
    restart = u.get("Restart", "no")
    lines.append("U_RESTART=%s" % sq(restart))
    try:
        rs = parse_time_ms(u.get("RestartSec", "100ms"))
    except ValueError:
        rs = 100
    lines.append("U_RESTART_MS=%d" % (rs or 0))
    codes, sigs = parse_status_set(u.words("SuccessExitStatus"))
    lines.append(sh_array("U_SUCCESS_CODES", [0] + codes))
    lines.append(sh_array("U_SUCCESS_SIGNALS", sigs))
    codes, sigs = parse_status_set(u.words("RestartPreventExitStatus"))
    lines.append(sh_array("U_PREVENT_CODES", codes))
    lines.append(sh_array("U_PREVENT_SIGNALS", sigs))
    codes, sigs = parse_status_set(u.words("RestartForceExitStatus"))
    lines.append(sh_array("U_FORCE_CODES", codes))
    lines.append(sh_array("U_FORCE_SIGNALS", sigs))
    try:
        interval = parse_time_ms(u.uget("StartLimitIntervalSec", u.get("StartLimitInterval", "10s")))
    except ValueError:
        interval = 10000
    lines.append("U_START_LIMIT_INTERVAL_MS=%d" % (interval or 0))
    burst = u.uget("StartLimitBurst", u.get("StartLimitBurst", "5"))
    lines.append("U_START_LIMIT_BURST=%s" % sq(burst if burst.isdigit() else "5"))
    start_ms, stop_ms = timeouts(u)
    lines.append("U_TIMEOUT_START_MS=%d" % start_ms)
    lines.append("U_TIMEOUT_STOP_MS=%d" % stop_ms)
    lines.append("U_PIDFILE=%s" % sq(expand_specifiers(u, u.get("PIDFile", ""))))
    lines.append("U_BUSNAME=%s" % sq(u.get("BusName", "")))
    lines.append("U_PERMISSIONS_START_ONLY=%d" % parse_bool(u.get("PermissionsStartOnly")))
    notify_fd = u.get("X-NotifyFd", "")
    if notify_fd and not notify_fd.isdigit():
        report.add(u.name, "ignored", "X-NotifyFd=%s is not a number" % notify_fd)
        notify_fd = ""
    if notify_fd and u.all("ExecStartPost"):
        report.add(u.name, "exec", "ExecStartPost= runs without waiting for readiness when X-NotifyFd= is used")
    lines.append("U_NOTIFY_FD=%s" % sq(notify_fd))
    # Type=notify-reload: reloading means sending this signal to the main process
    lines.append("U_RELOAD_SIGNAL=%s" % sq(
        (parse_signal(u.get("ReloadSignal", "HUP")) or "HUP") if typ == "notify-reload" else ""))
    emit_exec_context(u, "Service", lines, report)

    for key, fname in (
        ("ExecCondition", "condition"), ("ExecStartPre", "start_pre"),
        ("ExecStart", "start"), ("ExecStartPost", "start_post"),
        ("ExecReload", "reload"), ("ExecStop", "stop"), ("ExecStopPost", "stop_post"),
    ):
        emit_exec_list(u, lines, fname, key, "Service", report)

    sockets = []
    for sname in ctx.sockets_of.get(u.name, []):
        su = ctx.units[sname]
        fdname = su.get("FileDescriptorName", sname)
        for i, _ in enumerate(socket_listeners(su)):
            sockets.append("%s\x1f%s:%d" % (fdname, sname, i))
    lines.append(sh_array("U_SOCKETS", sockets))

    unknown = sorted(
        k for k in u.settings.keys("Service")
        if k not in SERVICE_KEYS_HANDLED and k not in IGNORED_QUIETLY["Service"] and k not in SANDBOX_KEYS
    )
    if unknown:
        report.add(u.name, "ignored", "unsupported [Service] settings: " + " ".join(unknown))
    return "\n".join(lines) + "\n"


def emit_mount(u, ctx):
    lines = []
    emit_common(u, lines)
    lines.append("U_HARD_FAIL=%d" % (u.name in ctx.required_units))
    lines.append("U_WHAT=%s" % sq(expand_specifiers(u, u.get("What", ""))))
    where = u.get("Where") or unescape_path(u.prefix)
    lines.append("U_WHERE=%s" % sq(expand_specifiers(u, where)))
    lines.append("U_FSTYPE=%s" % sq(u.get("Type", "")))
    lines.append("U_OPTIONS=%s" % sq(u.get("Options", "")))
    lines.append("U_DIR_MODE=%s" % sq(u.get("DirectoryMode", "0755")))
    lines.append("U_LAZY_UNMOUNT=%d" % parse_bool(u.get("LazyUnmount")))
    lines.append("U_FORCE_UNMOUNT=%d" % parse_bool(u.get("ForceUnmount")))
    lines.append("U_FSCK=%d" % parse_bool(u.get("X-Fsck")))
    return "\n".join(lines) + "\n"


def emit_target(u, ctx):
    lines = []
    emit_common(u, lines)
    return "\n".join(lines) + "\n"


def emit_swap(u, ctx):
    lines = []
    emit_common(u, lines)
    lines.append("U_HARD_FAIL=%d" % (u.name in ctx.required_units))
    lines.append("U_WHAT=%s" % sq(u.get("What") or unescape_path(u.prefix)))
    lines.append("U_OPTIONS=%s" % sq(u.get("Options", "")))
    lines.append("U_PRIORITY=%s" % sq(u.get("Priority", "")))
    return "\n".join(lines) + "\n"


LISTEN_KEYS = (
    ("ListenStream", "stream"), ("ListenDatagram", "dgram"),
    ("ListenSequentialPacket", "seqpacket"), ("ListenFIFO", "fifo"),
    ("ListenNetlink", "netlink"), ("ListenSpecial", "special"),
)


def socket_listeners(u):
    """[(kind, address)] in file order; the order defines the fd numbers."""
    out = []
    for s, k, v in u.settings.items:
        if s != "Socket":
            continue
        for key, kind in LISTEN_KEYS:
            if k == key:
                if v == "":
                    out = [x for x in out if x[0] != kind]
                else:
                    out.append((kind, expand_specifiers(u, v)))
    return out


def emit_socket(u, ctx):
    report = ctx.report
    lines = []
    emit_common(u, lines)
    lines.append("U_HARD_FAIL=%d" % (u.name in ctx.required_units))
    listeners = socket_listeners(u)
    lines.append(sh_array("U_LISTEN", ["%s\x1f%s" % l for l in listeners]))
    lines.append("U_SOCKET_MODE=%s" % sq(u.get("SocketMode", "0666")))
    lines.append("U_SOCKET_USER=%s" % sq(u.get("SocketUser", "")))
    lines.append("U_SOCKET_GROUP=%s" % sq(u.get("SocketGroup", "")))
    lines.append("U_SOCKET_DIR_MODE=%s" % sq(u.get("DirectoryMode", "0755")))
    lines.append("U_BACKLOG=%s" % sq(u.get("Backlog", "")))
    lines.append("U_BIND_IPV6_ONLY=%s" % sq(u.get("BindIPv6Only", "default")))
    lines.append("U_REUSE_PORT=%d" % parse_bool(u.get("ReusePort")))
    lines.append("U_FREE_BIND=%d" % parse_bool(u.get("FreeBind")))
    lines.append("U_PASS_CRED=%d" % parse_bool(u.get("PassCredentials")))
    lines.append("U_REMOVE_ON_STOP=%d" % parse_bool(u.get("RemoveOnStop")))
    lines.append(sh_array("U_SYMLINKS", [expand_specifiers(u, w) for w in u.words("Symlinks")]))
    lines.append("U_ACCEPT=%d" % accepts(u))
    # the service it starts again after it stopped (socket-activate)
    svc = None if accepts(u) else socket_service(u, ctx.loader)
    if svc in ctx.units and service_type(ctx.units[svc]) != "oneshot":
        lines.append("U_SERVICE_UNIT=%s" % sq(svc))
        lines.append("U_SERVICE_ATOM=%s" % sq(ctx.units[svc].atom))
    if accepts(u):
        template = socket_service(u, ctx.loader)
        lines.append("U_ACCEPT_UNIT=%s" % sq(template))
        lines.append("U_ACCEPT_DATA=%s" % sq(os.path.join(ctx.final_out, "unit-data", template)))
        lines.append("U_ACCEPT_MAX=%s" % sq(u.get("MaxConnections", "64")))
    emit_exec_context(u, "Socket", lines, report)
    for key, fname in (
        ("ExecStartPre", "start_pre"), ("ExecStartPost", "start_post"),
        ("ExecStopPre", "stop_pre"), ("ExecStopPost", "stop_post"),
    ):
        emit_exec_list(u, lines, fname, key, "Socket", report)
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# The graph

class Context:
    pass


# The instance name an Accept=yes socket's template service is compiled with;
# unit-runtime puts the real one (COUNTER-LOCAL-REMOTE) in its place for each
# connection.  Letters only: it passes through escaping unchanged.
ACCEPT_PLACEHOLDER = "ACCEPTINSTANCEPLACEHOLDER"


def accepts(u):
    return u.kind == "socket" and bool(parse_bool(u.get("Accept")))


def socket_service(u, loader):
    if accepts(u):
        return "%s@%s.service" % (u.prefix, ACCEPT_PLACEHOLDER)
    name = u.get("Service")
    if name:
        return loader.canonical(name)
    if u.instance is not None:
        return "%s@%s.service" % (u.prefix, u.instance)
    return u.prefix + ".service"


def path_service(u, loader):
    name = u.get("Unit")
    if name:
        return loader.canonical(name)
    if u.instance is not None:
        return "%s@%s.service" % (u.prefix, u.instance)
    return u.prefix + ".service"


def timer_service(u, loader):
    name = u.get("Unit")
    if name:
        return loader.canonical(name)
    if u.instance is not None:
        return "%s@%s.service" % (u.prefix, u.instance)
    return u.prefix + ".service"


def device_unit_for(what):
    """Name of the .device unit a mount or swap source corresponds to, if any."""
    what = (what or "").strip()
    for tag, d in (("UUID=", "by-uuid"), ("LABEL=", "by-label"),
                   ("PARTUUID=", "by-partuuid"), ("PARTLABEL=", "by-partlabel")):
        if what.startswith(tag):
            what = "/dev/disk/%s/%s" % (d, what[len(tag):].strip('"'))
    if not what.startswith("/dev/"):
        return None
    return escape_path(what) + ".device"


def compilable(u, report):
    """Does this unit describe something we can turn into a service?"""
    if u.masked:
        return False
    if u.kind == "service":
        has_cmd = bool(u.all("ExecStart")) or bool(u.all("ExecStop"))
        if not has_cmd:
            if u.has_file or u.settings.items:
                report.add(u.name, "stub", "has no ExecStart=: only overrides for a unit that does not exist here")
            return False
        if u.get("Type") != "oneshot" and len(u.all("ExecStart")) > 1:
            report.add(u.name, "exec", "more than one ExecStart= on a non-oneshot service; using the last one")
        return True
    if u.kind == "socket":
        return bool(socket_listeners(u))
    if u.kind == "mount":
        return bool(u.get("What"))
    if u.kind == "swap":
        return True
    if u.kind in ("target", "device", "timer"):
        return True
    if u.kind == "path":
        return True
    if u.kind in ("slice", "scope"):
        return False
    if u.kind == "automount":
        report.add(u.name, "unsupported", ".%s units are not supported yet" % u.kind)
        return False
    return False


def build_graph(loader, report, default_target):
    # 1. load everything in the directory, then everything those refer to
    units = {}
    queue = list(loader.names()) + [default_target]
    dep_keys = ("Requires", "Wants", "BindsTo", "PartOf", "Requisite", "Upholds", "After", "Before")
    while queue:
        name = loader.canonical(queue.pop())
        if name in units:
            continue
        u = loader.load(name)
        if u is None:
            units[name] = None
            continue
        units[name] = u
        for key in dep_keys:
            for w in u.uwords(key):
                queue.append(expand_specifiers(u, w))
        if u.kind == "socket":
            queue.append(socket_service(u, loader))
        if u.kind == "timer":
            queue.append(timer_service(u, loader))
        if u.kind == "path":
            queue.append(path_service(u, loader))
        if u.kind in ("mount", "swap"):
            dev = device_unit_for(u.get("What") or (unescape_path(u.prefix) if u.kind == "swap" else ""))
            if dev:
                queue.append(dev)

    units = {n: u for n, u in units.items() if u is not None and compilable(u, report)}

    # A timer or a path unit with nothing to start has nothing to do: what
    # sets such a unit up is usually only an override of a unit that is not
    # there (a configuration that turned the service off).
    for name, u in list(units.items()):
        if u.kind == "timer":
            target = timer_service(u, loader)
        elif u.kind == "path":
            target = path_service(u, loader)
        else:
            continue
        if target not in units:
            report.add(name, "dropped", "%s does not exist here; the unit is left out" % target)
            del units[name]

    # A unit that requires something which does not exist can never start
    # (systemd refuses it too).  Leave it out, and whatever required it in turn.
    changed = True
    while changed:
        changed = False
        for name, u in list(units.items()):
            for key in ("Requires", "BindsTo", "Requisite"):
                missing = [
                    n for n in (loader.canonical(expand_specifiers(u, w)) for w in u.uwords(key))
                    if is_unit_name(n) and n != name and n not in units
                    and split_name(n)[2] not in ("slice", "scope")
                ]
                if missing:
                    report.add(name, "dropped", "%s=%s, which does not exist here; the unit is left out"
                               % (key, " ".join(missing)))
                    del units[name]
                    changed = True
                    break

    def refs(u, key):
        out = set()
        for w in u.uwords(key):
            n = loader.canonical(expand_specifiers(u, w))
            if not is_unit_name(n):
                continue
            if n == u.name:
                continue
            if n in units:
                out.add(n)
            elif key not in ("Before", "After") and split_name(n)[2] not in ("slice", "scope"):
                # Ordering against a unit that does not exist is a no-op in
                # systemd as well; a missing requirement is worth a note.
                report.add(u.name, "reference", "%s=%s: no such unit here" % (key, n))
        return out

    for u in units.values():
        u.requires = refs(u, "Requires") | refs(u, "Requisite")
        u.binds_to = refs(u, "BindsTo")
        u.wants = refs(u, "Wants") | refs(u, "Upholds")
        u.after = refs(u, "After")
        u.before = refs(u, "Before")

    # 2. implicit and default dependencies
    ctx_sockets = defaultdict(list)
    for u in list(units.values()):
        defaults = parse_bool(u.uget("DefaultDependencies"), True)
        kind = u.kind

        def weak(names):
            for n in names:
                if n in units and n != u.name and n not in u.after:
                    u.weak_after.add(n)

        if kind == "service":
            if defaults:
                if "sysinit.target" in units:
                    u.requires.add("sysinit.target")
                weak(["sysinit.target", "basic.target"])
        elif kind == "target":
            if defaults:
                for n in u.requires | u.wants | u.binds_to:
                    other = units[n]
                    if u.name in other.after or n in u.before:
                        continue   # explicitly ordered the other way round
                    if not parse_bool(other.uget("DefaultDependencies"), True) and u.name not in other.before:
                        # systemd adds After= here regardless; an early unit
                        # that wants to come after its target says so itself.
                        pass
                    u.weak_after.add(n)
        elif kind == "socket":
            if defaults:
                if "sysinit.target" in units:
                    u.requires.add("sysinit.target")
                weak(["sysinit.target"])
                if "sockets.target" in units:
                    u.before.add("sockets.target")
            svc = socket_service(u, loader)
            if accepts(u):
                # one instance per connection: nothing to start, nothing to hand over
                if svc not in units:
                    report.add(u.name, "reference", "Accept=yes, and %s does not exist here" % svc)
            elif svc in units:
                # Started when something comes on the socket (the socket's
                # -activate atom, see cmd_socket_activate), as with systemd:
                # not at boot.  (incus-user, started right away, made the
                # network that `incus admin init` then found taken.)
                u.before.add(svc)
                if service_type(units[svc]) == "oneshot":
                    # (nothing waits on the socket for one of these: as before)
                    u.wants.add(svc)
                ctx_sockets[svc].append(u.name)
        elif kind == "timer":
            if defaults:
                if "sysinit.target" in units:
                    u.requires.add("sysinit.target")
                weak(["sysinit.target"])
                if "timers.target" in units:
                    u.before.add("timers.target")
                if u.all("OnCalendar"):
                    weak(["time-set.target", "time-sync.target"])
        elif kind == "path":
            if defaults:
                if "sysinit.target" in units:
                    u.requires.add("sysinit.target")
                weak(["sysinit.target"])
                if "paths.target" in units:
                    u.before.add("paths.target")
        elif kind == "mount":
            where = u.get("Where") or unescape_path(u.prefix)
            opts = (u.get("Options", "") or "").split(",")
            fstype = u.get("Type", "")
            network = "_netdev" in opts or fstype in ("nfs", "nfs4", "cifs", "smb3", "ceph", "glusterfs", "9p", "sshfs")
            if defaults:
                if network:
                    weak(["remote-fs-pre.target", "network.target", "network-online.target"])
                    if "remote-fs.target" in units:
                        u.before.add("remote-fs.target")
                else:
                    weak(["local-fs-pre.target"])
                    if "local-fs.target" in units and not where.startswith(("/sys", "/proc", "/dev", "/run")):
                        u.before.add("local-fs.target")
            # parent mount points first
            parent = os.path.dirname(where.rstrip("/"))
            while parent and parent != "/":
                pm = escape_path(parent) + ".mount"
                if pm in units:
                    u.requires.add(pm)
                    u.after.add(pm)
                    break
                parent = os.path.dirname(parent)
        elif kind == "swap":
            if defaults and "swap.target" in units:
                u.before.add("swap.target")

        if kind in ("mount", "swap"):
            dev = device_unit_for(u.get("What") or (unescape_path(u.prefix) if kind == "swap" else ""))
            if dev in units:
                opts = (u.get("Options", "") or "").split(",")
                (u.wants if "nofail" in opts else u.requires).add(dev)
                u.after.add(dev)

        for key, hard in (("RequiresMountsFor", True), ("WantsMountsFor", False)):
            for path in u.uwords(key):
                p = expand_specifiers(u, path)
                while p and p != "/":
                    pm = escape_path(p) + ".mount"
                    if pm in units and pm != u.name:
                        (u.requires if hard else u.wants).add(pm)
                        u.after.add(pm)
                    p = os.path.dirname(p)

    # 3. make ordering one-directional: `after` only
    for u in units.values():
        for n in u.before:
            if n in units:
                units[n].after.add(u.name)
    for u in units.values():
        u.weak_after -= u.after
        # binding without ordering is meaningless for a start job
        for n in u.binds_to:
            u.requires.add(n)

    return units, ctx_sockets


def refs_of(u, key):
    """Names listed under `key` in [Unit], canonical, specifiers expanded."""
    loader = CTX_LOADER
    return [
        loader.canonical(expand_specifiers(u, w))
        for w in u.uwords(key)
        if is_unit_name(loader.canonical(expand_specifiers(u, w)))
    ]


CTX_LOADER = None


def pull_closure(units, roots):
    seen = set()
    stack = [r for r in roots if r in units]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        u = units[n]
        stack.extend(x for x in (u.requires | u.wants) if x in units and x not in seen)
    return seen


# --------------------------------------------------------------------------
# Emitting s6-rc source

def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def exl_quote(s):
    """Quote a word for the execline lexer."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'


class Emitter:
    def __init__(self, args, ctx):
        self.args = args
        self.ctx = ctx
        self.data = os.path.join(args.out, "unit-data")
        self.atoms = {}     # atom name -> {"type":…, "deps": set(), …}
        os.makedirs(self.data, exist_ok=True)

    def data_path(self, unit):
        return os.path.join(self.data, unit)

    def runtime(self, verb, unit, *extra):
        words = [self.args.runtime, verb, os.path.join(self.args.final_out, "unit-data", unit)] + list(extra)
        return " ".join(exl_quote(w) for w in words)

    def add_atom(self, name, typ, unit):
        if name in self.atoms:
            die("service name collision on %r (units %s and %s)" % (name, self.atoms[name]["unit"], unit))
        if name.startswith(("s6rc-", "s6-rc-")):
            die("unit %s maps to the reserved s6-rc name %r" % (unit, name))
        # deps: everything that must be up first (boot database)
        # hard: the subset that is a real requirement (steady database)
        self.atoms[name] = {"type": typ, "unit": unit, "deps": set(), "hard": set(), "files": {}}
        return self.atoms[name]

    def require(self, name, dep):
        """A dependency that holds in both databases."""
        self.atoms[name]["deps"].add(dep)
        self.atoms[name]["hard"].add(dep)

    def flush(self, src, key):
        for name, a in sorted(self.atoms.items()):
            d = os.path.join(src, name)
            os.makedirs(d, exist_ok=True)
            write(os.path.join(d, "type"), a["type"] + "\n")
            for fname, (text, mode) in a["files"].items():
                write(os.path.join(d, fname), text, mode)
            if a[key]:
                dd = os.path.join(d, "dependencies.d")
                os.makedirs(dd, exist_ok=True)
                for dep in sorted(a[key]):
                    write(os.path.join(dd, dep), "")
            if a["type"] == "bundle":
                cd = os.path.join(d, "contents.d")
                os.makedirs(cd, exist_ok=True)
                for member in sorted(a.get("contents", ())):
                    write(os.path.join(cd, member), "")


def emit_units(args, ctx, em):
    units = ctx.units
    bash = args.bash
    for name in sorted(units):
        u = units[name]
        kind = u.kind
        if kind == "service":
            write(em.data_path(name), emit_service(u, ctx))
            typ = service_type(u)
            start_ms, stop_ms = timeouts(u)
            if typ == "oneshot":
                a = em.add_atom(u.atom, "oneshot", name)
                a["files"]["up"] = (em.runtime("up", name) + "\n", 0o644)
                a["files"]["down"] = (em.runtime("down", name) + "\n", 0o644)
                if start_ms:
                    a["files"]["timeout-up"] = ("%d\n" % start_ms, 0o644)
                if stop_ms:
                    a["files"]["timeout-down"] = ("%d\n" % (stop_ms + 5000), 0o644)
                u.atoms = [u.atom]
                u.ready = [u.atom]
            else:
                a = em.add_atom(u.atom, "longrun", name)
                data = os.path.join(args.final_out, "unit-data", name)
                a["files"]["run"] = (
                    "#!%s\nexec %s run %s\n" % (bash, sq(args.runtime), sq(data)), 0o755)
                a["files"]["finish"] = (
                    "#!%s\nexec %s finish %s \"$@\"\n" % (bash, sq(args.runtime), sq(data)), 0o755)
                a["files"]["notification-fd"] = ("%d\n" % args.notification_fd, 0o644)
                if start_ms:
                    a["files"]["timeout-up"] = ("%d\n" % start_ms, 0o644)
                a["files"]["timeout-down"] = ("%d\n" % ((stop_ms + 10000) if stop_ms else 0), 0o644)
                if stop_ms and parse_bool(u.get("SendSIGKILL"), True):
                    a["files"]["timeout-kill"] = ("%d\n" % stop_ms, 0o644)
                a["files"]["timeout-finish"] = ("%d\n" % max(20000, min(stop_ms or 90000, 90000)), 0o644)
                sig = parse_signal(u.get("KillSignal", "TERM")) or "TERM"
                a["files"]["down-signal"] = ("SIG%s\n" % sig, 0o644)
                u.atoms = [u.atom]
                u.ready = [u.atom]
                if u.get("StandardOutput", "journal") not in ("null", "tty") or u.get("StandardError", "inherit") not in ("null", "tty"):
                    log = em.add_atom(u.atom + "-log", "longrun", name)
                    a["files"]["producer-for"] = (u.atom + "-log\n", 0o644)
                    log["files"]["consumer-for"] = (u.atom + "\n", 0o644)
                    log["files"]["notification-fd"] = ("3\n", 0o644)
                    log["files"]["run"] = (
                        "#!%s\nexec %s log %s\n" % (bash, sq(args.runtime), sq(u.atom)), 0o755)
                    u.atoms.append(u.atom + "-log")
                if u.all("ExecStop"):
                    hooks = em.add_atom(u.atom + "-hooks", "oneshot", name)
                    hooks["files"]["up"] = ("", 0o644)
                    hooks["files"]["down"] = (em.runtime("stop-hook", name) + "\n", 0o644)
                    hooks["files"]["timeout-down"] = ("%d\n" % ((stop_ms + 5000) if stop_ms else 0), 0o644)
                    em.require(u.atom + "-hooks", u.atom)
                    u.atoms.append(u.atom + "-hooks")
                    u.ready.append(u.atom + "-hooks")
        elif kind == "target":
            # (it says so: "Reached target …" is what things look for in a
            # journal to know the system is up, graphical-session.target in
            # particular)
            write(em.data_path(name), emit_target(u, ctx))
            a = em.add_atom(u.atom, "oneshot", name)
            a["files"]["up"] = (em.runtime("target-up", name) + "\n", 0o644)
            u.atoms = u.ready = [u.atom]
        elif kind in ("mount", "swap"):
            write(em.data_path(name), emit_mount(u, ctx) if kind == "mount" else emit_swap(u, ctx))
            a = em.add_atom(u.atom, "oneshot", name)
            a["files"]["up"] = (em.runtime(kind + "-up", name) + "\n", 0o644)
            a["files"]["down"] = (em.runtime(kind + "-down", name) + "\n", 0o644)
            u.atoms = u.ready = [u.atom]
        elif kind == "socket":
            write(em.data_path(name), emit_socket(u, ctx))
            a = em.add_atom(u.atom, "oneshot", name)
            a["files"]["up"] = (em.runtime("socket-up", name) + "\n", 0o644)
            a["files"]["down"] = (em.runtime("socket-down", name) + "\n", 0o644)
            em.require(u.atom, args.fdholder)
            u.atoms = u.ready = [u.atom]
            if accepts(u):
                # the service that takes the connections off the sockets
                acc = em.add_atom(u.atom + "-accept", "longrun", name)
                data = os.path.join(args.final_out, "unit-data", name)
                acc["files"]["run"] = (
                    "#!%s\nexec %s accept-loop %s\n" % (bash, sq(args.runtime), sq(data)), 0o755)
                em.require(u.atom + "-accept", u.atom)
                u.atoms.append(u.atom + "-accept")
            else:
                # what starts the service when a connection comes, at first
                # and again after it stopped
                svc = socket_service(u, ctx.loader)
                if svc in units and service_type(units[svc]) != "oneshot":
                    act = em.add_atom(u.atom + "-activate", "longrun", name)
                    data = os.path.join(args.final_out, "unit-data", name)
                    act["files"]["run"] = (
                        "#!%s\nexec %s socket-activate %s\n" % (bash, sq(args.runtime), sq(data)), 0o755)
                    em.require(u.atom + "-activate", u.atom)
                    u.atoms.append(u.atom + "-activate")
        elif kind == "device":
            path = None
            if u.prefix.startswith("dev-"):
                path = unescape_path(u.prefix)
            elif u.prefix.startswith("sys-"):
                path = unescape_path(u.prefix)
            if path is None:
                ctx.report.add(name, "unsupported", "cannot map device unit to a path")
                path = "/"
            try:
                tmo = parse_time_ms(u.uget("JobRunningTimeoutSec", u.uget("JobTimeoutSec", "90s"))) or 0
            except ValueError:
                tmo = 90000
            a = em.add_atom(u.atom, "oneshot", name)
            hard = "1" if name in ctx.required_units else "0"
            if name in ctx.trigger_devices:
                # Only there to start other units when the device exists: look
                # once, after the initial device events have been processed.
                tmo = -1
                hard = "1"
                settle = units.get(ctx.loader.canonical("systemd-udev-settle.service"))
                if settle is not None:
                    em.require(u.atom, settle.atom)
            a["files"]["up"] = (
                " ".join(exl_quote(w) for w in [args.runtime, "device", name, path, str(tmo), hard]) + "\n", 0o644)
            u.atoms = u.ready = [u.atom]
        elif kind == "path":
            svc = path_service(u, ctx.loader)
            if svc not in units:
                ctx.report.add(name, "reference", "path unit for %s, which does not exist here" % svc)
            lines = []
            emit_common(u, lines)
            watch = []
            for key in ("PathExists", "PathExistsGlob", "PathChanged", "PathModified", "DirectoryNotEmpty"):
                for v in u.all(key):
                    watch.append("%s\x1f%s" % (key, expand_specifiers(u, v)))
            lines.append(sh_array("U_PATHS", watch))
            lines.append("U_PATH_UNIT=%s" % sq(svc))
            lines.append("U_PATH_MAKE_DIR=%d" % parse_bool(u.get("MakeDirectory")))
            lines.append("U_PATH_DIR_MODE=%s" % sq(u.get("DirectoryMode", "0755")))
            write(em.data_path(name), "\n".join(lines) + "\n")
            a = em.add_atom(u.atom, "longrun", name)
            data = os.path.join(args.final_out, "unit-data", name)
            a["files"]["run"] = ("#!%s\nexec %s path %s\n" % (bash, sq(args.runtime), sq(data)), 0o755)
            u.atoms = u.ready = [u.atom]
        elif kind == "timer":
            svc = timer_service(u, ctx.loader)
            if svc not in units:
                ctx.report.add(name, "reference", "timer for %s, which does not exist here" % svc)
            lines = []
            emit_common(u, lines)
            timer_args = []
            for key in ("OnCalendar", "OnActiveSec", "OnBootSec", "OnStartupSec", "OnUnitActiveSec", "OnUnitInactiveSec"):
                for v in u.all(key):
                    timer_args.append("%s=%s" % (key, v))
            for key in ("AccuracySec", "RandomizedDelaySec", "Persistent", "FixedRandomDelay", "WakeSystem", "RemainAfterElapse", "OnClockChange", "OnTimezoneChange", "RandomizedOffsetSec", "DeferReactivation"):
                v = u.get(key)
                if v is not None:
                    timer_args.append("%s=%s" % (key, v))
            lines.append(sh_array("U_TIMER", timer_args))
            lines.append("U_TIMER_SERVICE=%s" % sq(svc))
            lines.append("U_TIMER_SERVICE_DATA=%s" % sq(os.path.join(args.final_out, "unit-data", svc)))
            write(em.data_path(name), "\n".join(lines) + "\n")
            a = em.add_atom(u.atom, "longrun", name)
            data = os.path.join(args.final_out, "unit-data", name)
            a["files"]["run"] = ("#!%s\nexec %s timer %s\n" % (bash, sq(args.runtime), sq(data)), 0o755)
            u.atoms = u.ready = [u.atom]


def emit_native(path, em):
    """Services written directly for s6-rc (the `s6.rc.services` option).

    Returns the names that belong in the default bundle."""
    with open(path) as f:
        spec = json.load(f)
    for name, svc in sorted(spec.get("services", {}).items()):
        a = em.add_atom(name, svc["type"], "(native)")
        for fname, f in svc.get("files", {}).items():
            a["files"][fname] = (f["text"], int(f.get("mode", "0644"), 8))
        for dep in svc.get("dependencies", []):
            em.require(name, dep)
        if svc["type"] == "bundle":
            a["contents"] = list(svc.get("contents", []))
    return list(spec.get("default", []))


def break_cycles(ctx, em):
    """Remove dependency edges until the atom graph is acyclic."""
    atoms = em.atoms

    def find_cycle():
        WHITE, GREY, BLACK = 0, 1, 2
        color = {a: WHITE for a in atoms}
        for start in sorted(atoms):
            if color[start] != WHITE:
                continue
            stack = [(start, iter(sorted(atoms[start]["deps"])))]
            path = [start]
            color[start] = GREY
            while stack:
                node, it = stack[-1]
                advanced = False
                for nxt in it:
                    if nxt not in atoms:
                        continue
                    if color[nxt] == GREY:
                        return path[path.index(nxt):] + [nxt]
                    if color[nxt] == WHITE:
                        color[nxt] = GREY
                        stack.append((nxt, iter(sorted(atoms[nxt]["deps"]))))
                        path.append(nxt)
                        advanced = True
                        break
                if not advanced:
                    color[node] = BLACK
                    stack.pop()
                    path.pop()
        return None

    while True:
        cycle = find_cycle()
        if not cycle:
            return
        edges = list(zip(cycle, cycle[1:]))
        edges.sort(key=lambda e: (ctx.edge_strength.get(e, 0), e))
        a, b = edges[0]
        atoms[a]["deps"].discard(b)
        ctx.report.add(
            atoms[a]["unit"], "cycle",
            "ordering cycle %s; dropped the dependency of %s on %s" % (" -> ".join(cycle), a, b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--units", required=True, help="directory of unit files")
    ap.add_argument("--out", required=True)
    ap.add_argument("--final-out", help="where --out will live on the target (defaults to --out)")
    ap.add_argument("--runtime", required=True, help="path of the unit runtime script")
    ap.add_argument("--bash", required=True)
    ap.add_argument("--default", default="default.target")
    ap.add_argument("--fdholder", default="unit-fdholder", help="name of the fd holder service")
    ap.add_argument("--notification-fd", type=int, default=20)
    ap.add_argument("--native", help="JSON description of native s6-rc services to add")
    ap.add_argument("--scope", choices=("system", "user"), default="system",
                    help="whose units these are")
    ap.add_argument("--strict", action="store_true", help="fail on unknown references")
    args = ap.parse_args()
    args.final_out = args.final_out or args.out
    global SCOPE
    SCOPE = args.scope

    report = Report()
    loader = Loader(args.units, report)
    default_target = loader.canonical(args.default)
    units, sockets_of = build_graph(loader, report, default_target)
    if default_target not in units:
        die("default unit %s is not defined" % default_target)

    global CTX_LOADER
    CTX_LOADER = loader
    ctx = Context()
    ctx.units = units
    ctx.loader = loader
    ctx.final_out = args.final_out
    ctx.report = report
    ctx.sockets_of = sockets_of

    # Devices that units are "wanted by": systemd starts those units when the
    # device appears.  A device that is there at boot is there once udev has
    # settled, so such devices join the boot transaction as a one-time check;
    # the units they want are held back by them (they bind to the device) and
    # start in their proper place if it exists.  A device counts as a mere
    # trigger when nothing but the units it wants depends on it.
    triggers = set()
    for name, u in units.items():
        if u.kind != "device" or not u.wants:
            continue
        others = [
            o for o in units.values()
            if o.name != name and name in (o.requires | o.wants | o.after) and o.name not in u.wants
        ]
        if not others:
            triggers.add(name)
    ctx.trigger_devices = triggers
    roots = [default_target] + sorted(triggers)

    boot = pull_closure(units, roots)
    # a socket is only handed to its service if the socket is started at boot
    # or the service asks for it explicitly
    for svc, socks in list(sockets_of.items()):
        keep = [s for s in socks if s in boot or s in units[svc].requires or s in units[svc].wants]
        for s in keep:
            units[svc].requires.add(s)
            units[svc].after.add(s)
        sockets_of[svc] = keep
    boot = pull_closure(units, roots)

    required = set()
    for u in units.values():
        required |= u.requires
    ctx.required_units = required

    em = Emitter(args, ctx)
    emit_units(args, ctx, em)
    native_default = emit_native(args.native, em) if args.native else []

    # dependencies between atoms
    ctx.edge_strength = {}
    closures = {}

    def own_atoms(u):
        """Atoms of a unit that take part in ordering (not its logger or hooks)."""
        return [a for a in u.atoms if a == u.atom or not a.endswith(("-log", "-hooks"))]

    for name, u in units.items():
        closure = pull_closure(units, [name])
        closures[name] = closure
        for other_name in u.requires | u.after | u.weak_after:
            other = units.get(other_name)
            if other is None or not other.ready:
                continue
            hard = other_name in u.requires
            if not hard and other_name not in boot and other_name not in closure:
                continue
            if hard:
                # (a requirement that is also ordered is the last to give way
                # in a cycle: BindsTo= of cockpit's sockets on cockpit.service,
                # which orders nothing, against cockpit's Requires=+After= on
                # them - dropping the latter started cockpit without them)
                strength = 4 if other_name in u.after else 3
            elif other_name in u.wants:
                strength = 2
            elif other_name in u.after:
                strength = 1
            else:
                strength = 0
            for a in own_atoms(u):
                for b in other.ready:
                    if a == b:
                        continue
                    em.atoms[a]["deps"].add(b)
                    if hard:
                        em.atoms[a]["hard"].add(b)
                    ctx.edge_strength[(a, b)] = max(strength, ctx.edge_strength.get((a, b), 0))

    break_cycles(ctx, em)
    for a in em.atoms.values():
        a["hard"] &= a["deps"]

    # rank: grows along every ordering edge.  Sorting any set of services by
    # it gives an order that respects After=/Before=.
    rank = {}

    def rank_of(name):
        stack = [(name, iter(sorted(em.atoms[name]["deps"])))]
        while stack:
            node, it = stack[-1]
            for dep in it:
                if dep in em.atoms and dep not in rank:
                    stack.append((dep, iter(sorted(em.atoms[dep]["deps"]))))
                    break
            else:
                rank[node] = 1 + max((rank[d] for d in em.atoms[node]["deps"] if d in rank), default=0)
                stack.pop()
        return rank[name]

    for a in sorted(em.atoms):
        if a not in rank:
            rank_of(a)

    em.flush(os.path.join(args.out, "source-boot"), "deps")
    em.flush(os.path.join(args.out, "source"), "hard")

    # the "default" bundle: everything systemd would start for default.target
    boot_atoms = sorted({a for n in boot for a in units[n].atoms} | set(native_default))
    for tree in ("source-boot", "source"):
        bd = os.path.join(args.out, tree, "default")
        os.makedirs(os.path.join(bd, "contents.d"))
        write(os.path.join(bd, "type"), "bundle\n")
        for a in boot_atoms:
            write(os.path.join(bd, "contents.d", a), "")

    # index.tsv: what the tools on the running system need to know, in a form
    # a shell can read.  One line per unit:
    #   unit  kind  type  rank  boot(0/1)  main atom  atoms  start set
    index = []
    for name, u in sorted(units.items()):
        start = sorted({a for n in closures[name] for a in units[n].atoms})
        index.append("\t".join([
            name,
            u.kind,
            service_type(u) if u.kind == "service" else u.kind,
            str(max(rank[a] for a in u.atoms)),
            "1" if name in boot else "0",
            u.atom,
            " ".join(u.atoms),
            " ".join(start),
        ]))
    for alias in sorted(loader.aliases):
        target = loader.canonical(alias)
        if target in units:
            index.append("\t".join([alias, "alias", target, "0", "0", units[target].atom, "", ""]))
    write(os.path.join(args.out, "index.tsv"), "\n".join(index) + "\n")
    # devices.tsv: units to start when a device shows up (unit files linked
    # into X.device.wants).  One line per device:  path  units
    lines = []
    for name, u in sorted(units.items()):
        if u.kind != "device" or not u.wants:
            continue
        path = unescape_path(u.prefix)
        if path.startswith("/sys/subsystem/net/devices/"):
            path = "net:" + path[len("/sys/subsystem/net/devices/"):]
        lines.append("%s\t%s" % (path, " ".join(sorted(u.wants))))
    write(os.path.join(args.out, "devices.tsv"), "".join(l + "\n" for l in lines))

    # partof.tsv: units that go down with another (PartOf=, BindsTo=).
    # One line per unit that has such members:  unit  members…
    parts = defaultdict(set)
    for name, u in units.items():
        for target in set(refs_of(u, "PartOf")) | u.binds_to:
            if target in units:
                parts[target].add(name)
    write(os.path.join(args.out, "partof.tsv"),
          "".join("%s\t%s\n" % (t, " ".join(sorted(m))) for t, m in sorted(parts.items())))

    write(os.path.join(args.out, "ranks.tsv"),
          "".join("%d\t%s\n" % (rank[a], a) for a in sorted(em.atoms, key=lambda a: (rank[a], a))))

    manifest = {"default": default_target, "units": {}, "aliases": {}}
    for alias in sorted(loader.aliases):
        target = loader.canonical(alias)
        if target in units:
            manifest["aliases"][alias] = target
    for name, u in sorted(units.items()):
        h = hashlib.sha256()
        h.update(u.source_text.encode())
        data = em.data_path(name)
        if os.path.exists(data):
            with open(data, "rb") as f:
                h.update(f.read().replace(args.final_out.encode(), b"@out@"))
        svc = u.settings
        manifest["units"][name] = {
            "kind": u.kind,
            "type": service_type(u) if u.kind == "service" else u.kind,
            "atoms": u.atoms,
            "ready": u.ready,
            "start": sorted({a for n in closures[name] for a in units[n].atoms}),
            "boot": name in boot,
            "rank": max(rank[a] for a in u.atoms),
            "hash": h.hexdigest(),
            "description": u.uget("Description", ""),
            "restartIfChanged": parse_bool(svc.get("Service", "X-RestartIfChanged"), True),
            "reloadIfChanged": parse_bool(svc.get("Service", "X-ReloadIfChanged"), False),
            "stopIfChanged": parse_bool(svc.get("Service", "X-StopIfChanged"), True),
            "restartTriggers": svc.get("Unit", "X-Restart-Triggers", ""),
            "reloadTriggers": svc.get("Unit", "X-Reload-Triggers", ""),
            "refuseManualStart": parse_bool(svc.get("Unit", "RefuseManualStart"), False),
            "refuseManualStop": parse_bool(svc.get("Unit", "RefuseManualStop"), False),
        }
    write(os.path.join(args.out, "manifest.json"), json.dumps(manifest, indent=1, sort_keys=True) + "\n")

    # switch.tsv: what switch-to-configuration compares between two systems.
    #   unit  hash  restartIfChanged  reloadIfChanged  stopIfChanged  atoms
    lines = []
    for name, m in sorted(manifest["units"].items()):
        lines.append("\t".join([
            name, m["hash"],
            "1" if m["restartIfChanged"] else "0",
            "1" if m["reloadIfChanged"] else "0",
            "1" if m["stopIfChanged"] else "0",
            " ".join(a for a in m["atoms"] if not a.endswith("-log")),
        ]))
    write(os.path.join(args.out, "switch.tsv"), "\n".join(lines) + "\n")
    write(os.path.join(args.out, "report.txt"), report.text())

    n_atoms = len(em.atoms)
    sys.stderr.write(
        "unitc: %d units -> %d s6-rc services (%d in the default bundle); %d units with notes, see report.txt\n"
        % (len(units), n_atoms, len(boot_atoms), len(report.items)))


if __name__ == "__main__":
    main()
