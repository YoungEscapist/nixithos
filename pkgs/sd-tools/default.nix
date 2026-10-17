# tmpfiles and sysusers as standalone programs (a clean-up of the systemd
# code by the Chimera Linux project).  NixOS modules lean heavily on
# tmpfiles.d rules, so we need something that implements them faithfully.
{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  libcap,
  acl,
}:

stdenv.mkDerivation {
  pname = "sd-tools";
  version = "0.99.0-unstable-2026-03-05";

  src = fetchFromGitHub {
    owner = "chimera-linux";
    repo = "sd-tools";
    rev = "9919e8c2c57b88cf0ddb2182a2b53bce7d0733ac";
    hash = "sha256-Vk+9Aa5qus0/J9rMRYmCQCDerGkBtqUMwr8sd2HVI+s=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];

  buildInputs = [
    libcap
    acl
  ];

  # The list of system configuration directories is a compound literal that
  # goes out of scope before it is used.  GCC reuses its stack slot, and
  # sd-tmpfiles then finds no configuration at all unless files are named on
  # the command line.  Give the list static storage.
  #
  # %b and %m are read from /proc/sys/kernel/random/boot_id and
  # /etc/machine-id with the newline at the end, which then is part of the
  # path: `x /tmp/systemd-private-%b-*` matched nothing, and cleaning /tmp
  # emptied the PrivateTmp= directories of running services.  Stop at it.
  postPatch = ''
    substituteInPlace src/tmpfiles/tmpfiles.c --replace-fail \
      'config_dirs = CONF_PATHS_STRV("tmpfiles.d");' \
      '{ static const char *const system_dirs[] = { CONF_PATHS_USR("tmpfiles.d"), NULL }; config_dirs = (char **) system_dirs; }'
    substituteInPlace src/shared/specifier.c \
      --replace-fail \
        'if (*src == '"'"'-'"'"') continue;' \
        'if (*src == '"'"'\n'"'"') break; if (*src == '"'"'-'"'"') continue;' \
      --replace-fail \
        'return read_full_stream(f, ret, NULL);' \
        'r = read_full_stream(f, ret, NULL); if (r >= 0) (*ret)[strcspn(*ret, "\n")] = 0; return r;'
  '';

  mesonFlags = [ "-Dtests=false" ];

  meta = {
    description = "Standalone tmpfiles and sysusers, derived from systemd";
    homepage = "https://github.com/chimera-linux/sd-tools";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.linux;
  };
}
