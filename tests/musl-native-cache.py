#!/usr/bin/env python3
"""Ephemeral signed HTTPS cache for native-Nix QEMU tests; host stdlib only.

The fixture must be an input-addressed store path (a derivation output):
content-addressed paths such as `nix-store --add` results are self-certifying
and are substituted without any signature, so the rejection checks would fail.

Use on the live Nix host: a build sandbox normally lacks a readable local-store
database/daemon socket. Nothing is downloaded and no host store path is signed.
Only the destination cache narinfo is signed. Private keys stay in a temporary
0700 directory outside the HTTP document root and are removed on context exit.
"""
import argparse
import base64
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote


class TLSCache:
    """with TLSCache(nix=..., openssl=..., source=STORE_TEXT) as cache: ...

    Public fields: url, unsigned_url, public_key, wrong_public_key, certificate,
    source and requests. guest_check(console) exercises both negative cases and
    valid substitution through an existing musl-vm.Console serial session.
    """

    def __init__(self, nix, openssl, source, *, nix_store=None, temp_dir=None):
        self.nix = str(nix)
        self.nix_store = str(nix_store or Path(nix).with_name("nix-store"))
        self.openssl = str(openssl)
        self.source = str(Path(source).absolute())
        self.temp_dir = temp_dir
        self.requests = []
        self._temporary = None
        self._server = None
        self._thread = None

    def _run(self, arguments):
        # Arguments may contain ephemeral private-key paths. Never echo command
        # lines or captured key-generation output in failures/public reports.
        try:
            result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            raise RuntimeError(f"cache setup subprocess unavailable/timed out ({Path(arguments[0]).name})") from None
        if result.returncode:
            raise RuntimeError(f"cache setup subprocess failed ({Path(arguments[0]).name}, exit {result.returncode})")
        return result.stdout

    def __enter__(self):
        source = Path(self.source)
        if source.parent != Path("/nix/store") or not re.fullmatch(r"[a-z0-9]{32}-.+", source.name):
            raise ValueError("source must name one existing /nix/store text fixture output")
        if source.is_symlink() or not source.is_file() or source.stat().st_size > 1024 * 1024:
            raise ValueError("source must be a regular fixture file no larger than 1 MiB")
        closure = self._run([self.nix_store, "-qR", self.source]).splitlines()
        if closure != [self.source]:
            raise ValueError("fixture must have no other runtime store references")
        try:
            self._temporary = tempfile.TemporaryDirectory(prefix="musl-native-cache-", dir=self.temp_dir)
            root = Path(self._temporary.name)
            os.chmod(root, 0o700)
            private = root / "private"
            private.mkdir(mode=0o700)
            public = root / "public"
            public.mkdir()
            signed = public / "signed"
            signed.mkdir()
            for name in ("trusted", "wrong"):
                self._run([self.nix_store, "--generate-binary-cache-key", "musl-test-" + name,
                           str(private / (name + ".secret")), str(private / (name + ".public"))])
                os.chmod(private / (name + ".secret"), 0o600)
            self.public_key = (private / "trusted.public").read_text().strip()
            self.wrong_public_key = (private / "wrong.public").read_text().strip()
            destination = signed.as_uri() + "?secret-key=" + quote(str(private / "trusted.secret"), safe="/")
            self._run([self.nix, "--extra-experimental-features", "nix-command", "copy",
                       "--option", "substituters", "", "--to", destination, self.source])
            narinfos = list(signed.glob("*.narinfo"))
            if len(narinfos) != 1 or "\nSig: musl-test-trusted:" not in narinfos[0].read_text():
                raise RuntimeError("fixture cache did not receive exactly one signed narinfo")
            unsigned = public / "unsigned"
            shutil.copytree(signed, unsigned)
            for narinfo in unsigned.glob("*.narinfo"):
                narinfo.write_text("\n".join(line for line in narinfo.read_text().splitlines()
                                              if not line.startswith("Sig:")) + "\n")
            certificate = private / "certificate.pem"
            self._run([self.openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                       "-days", "1", "-subj", "/CN=musl-cache-test",
                       "-addext", "subjectAltName=IP:10.0.2.2,IP:127.0.0.1",
                       "-keyout", str(private / "tls.secret"), "-out", str(certificate)])
            self.certificate = certificate.read_text()
            requests = self.requests

            class Handler(SimpleHTTPRequestHandler):
                def log_message(self, format, *args):
                    pass

                def do_GET(self):
                    requests.append(self.path)
                    return super().do_GET()

            handler = functools.partial(Handler, directory=str(public))
            self._server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
            self._server.daemon_threads = True
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(certificate, private / "tls.secret")
            self._server.socket = context.wrap_socket(self._server.socket, server_side=True)
            self.port = self._server.server_address[1]
            self.url = f"https://10.0.2.2:{self.port}/signed"
            self.unsigned_url = f"https://10.0.2.2:{self.port}/unsigned"
            self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
            self._thread.start()
            return self
        except BaseException:
            self.close()
            raise

    def public_metadata(self):
        return {"url": self.url, "unsigned_url": self.unsigned_url,
                "public_key": self.public_key, "wrong_public_key": self.wrong_public_key,
                "certificate": self.certificate, "source": self.source}

    def guest_check(self, console, *, nix_store="/bin/nix-store", certificate_path="/run/musl-test-cache.pem"):
        """Require TLS and signatures; reject unsigned/wrong-key before success.

        The fixture MUST be absent from the booted image. console.check raises
        on failure; no alternate substituters or success fallback are allowed.
        """
        q = shlex.quote
        encoded_certificate = base64.b64encode(self.certificate.encode()).decode()
        console.check(f"test ! -e {q(self.source)}")
        # BusyBox ash line editing truncates long input lines; send short pieces.
        encoded_path = certificate_path + ".b64"
        console.check(f": > {q(encoded_path)}")
        for start in range(0, len(encoded_certificate), 400):
            console.check(f"printf %s {q(encoded_certificate[start:start + 400])} >> {q(encoded_path)}")
        console.check(f"/bin/busybox base64 -d {q(encoded_path)} > {q(certificate_path)}")

        def restore(url, key):
            return (f"{q(nix_store)} -r {q(self.source)} --option substituters {q(url)} "
                    f"--option extra-substituters '' --option trusted-public-keys {q(key)} "
                    f"--option ssl-cert-file {q(certificate_path)} --option require-sigs true "
                    "--option fallback false --option narinfo-cache-negative-ttl 0 "
                    "--option narinfo-cache-positive-ttl 0 --option connect-timeout 5")

        for name, url, key in [("unsigned", self.unsigned_url, self.public_key),
                               ("wrong-key", self.url, self.wrong_public_key)]:
            command = restore(url, key)
            logfile = "/run/musl-cache-" + name + ".log"
            console.check(f"if {command} > {q(logfile)} 2>&1; then false; else "
                          f"/bin/busybox cat {q(logfile)}; test ! -e {q(self.source)} && "
                          f"/bin/busybox grep -Ei 'not signed|signature|trusted-public-keys' {q(logfile)}; fi")
        narinfo_name = Path(self.source).name.split("-", 1)[0] + ".narinfo"
        for prefix in ("/unsigned/", "/signed/"):
            if prefix + narinfo_name not in self.requests:
                raise AssertionError("negative signature test did not fetch narinfo over the local TLS connection")
        console.check(restore(self.url, self.public_key))
        console.check(f"{q(nix_store)} --check-validity {q(self.source)} && test -f {q(self.source)}")
        if not any(path.startswith("/signed/nar/") for path in self.requests):
            raise AssertionError("valid substitution did not retrieve fixture NAR data over TLS")

    def close(self):
        if self._server is not None:
            if self._thread is not None:
                self._server.shutdown()
                self._thread.join(timeout=5)
            self._server.server_close()
            self._server = None
            self._thread = None
        if self._temporary is not None:
            self._temporary.cleanup()
            self._temporary = None

    def __exit__(self, exc_type, exc, traceback):
        self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nix", required=True, help="host nix executable")
    parser.add_argument("--nix-store", help="host nix-store executable (defaults beside nix)")
    parser.add_argument("--openssl", required=True, help="host openssl executable")
    parser.add_argument("--source", required=True, help="existing small text fixture output absent from guest")
    parser.add_argument("--temp-dir", type=Path)
    parser.add_argument("--serve-seconds", type=int, default=300)
    args = parser.parse_args()
    if args.serve_seconds < 1:
        parser.error("--serve-seconds must be positive")
    with TLSCache(args.nix, args.openssl, args.source, nix_store=args.nix_store, temp_dir=args.temp_dir) as cache:
        print(json.dumps(cache.public_metadata()), flush=True)
        try:
            end = time.monotonic() + args.serve_seconds
            while time.monotonic() < end:
                time.sleep(min(1, end - time.monotonic()))
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
