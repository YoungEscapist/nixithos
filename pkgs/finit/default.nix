# Finit is PID 1 and the native service manager. The NixithOS runtime keeps
# responsibility for per-unit credentials, namespaces and cgroups.
{ lib, stdenv, fetchurl, pkg-config, libite, libuev, libcap }:
stdenv.mkDerivation (finalAttrs: {
  pname = "finit";
  version = "4.17";

  src = fetchurl {
    url = "https://github.com/finit-project/finit/releases/download/${finalAttrs.version}/finit-${finalAttrs.version}.tar.gz";
    sha256 = "ca8b489a0ed99c17c0288e9e65e325a8f14af3734dfecf58f516c0a6f884e903";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libite libuev libcap ];
  configureFlags = [
    "--sysconfdir=/etc"
    "--localstatedir=/var"
    "--runstatedir=/run"
    "--with-fstab=/etc/finit.fstab"
    "--disable-doc"
    "--disable-contrib"
    "--disable-rescue"
    "--disable-cgroup"
    "--disable-logrotate"
    "--disable-kernel-logging"
    "--disable-hotplug-plugin"
    "--disable-rtc-plugin"
    "--disable-tty-plugin"
    "--disable-urandom-plugin"
    "--enable-fastboot"
  ];
  enableParallelBuilding = true;

  # Keep runtime paths in /etc and /run without installing into the build
  # machine's /etc. Configuration is supplied by modules/finit instead.
  installPhase = ''
    runHook preInstall
    make install DESTDIR="$TMPDIR/install"
    mv "$TMPDIR/install/$out" "$out"
    runHook postInstall
  '';

  meta = {
    description = "Fast init and service supervision for Linux";
    homepage = "https://github.com/finit-project/finit";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "finit";
  };
})
