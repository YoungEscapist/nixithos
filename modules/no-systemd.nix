# Keeping systemd out of the system closure, not just out of PID 1.
#
# nixpkgs builds its packages with systemd support: a good part of them is
# linked against libsystemd or libudev (which is part of systemd, too), and a
# few NixOS modules reach for a tool of the systemd package.  None of that
# makes systemd *run* here, but it does put it on the disk.  There are three
# ways to deal with it, chosen by `s6.systemdPackages`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  mode = config.s6.systemdPackages;

  # replaceDependencies swaps store paths inside binaries, so a replacement
  # has to have a name exactly as long as the one it replaces.
  # (the name of the store path, not the derivation's `name`: the "dev"
  # output of systemd-260.5 is systemd-260.5-dev)
  sameLengthAs =
    original: name:
    let
      path = builtins.unsafeDiscardStringContext (toString original);
      # /nix/store/<32 characters>-<name>
      originalName = builtins.substring 33 (-1) (baseNameOf path);
      n = lib.stringLength originalName;
    in
    assert lib.assertMsg (lib.stringLength name <= n) ''
      s6.systemdPackages = "replace": the replacement name "${name}" is longer than
      the name of what it replaces (${originalName}).
    '';
    name + lib.concatStrings (lib.genList (_: "_") (n - lib.stringLength name));

  # What takes the place of the systemd of a package set `p`: of the system's,
  # and on x86_64 also of the 32-bit one (pkgsi686Linux), which programs built
  # for 32 bits bring along (pulseaudio's support32Bit, Steam, the 32-bit
  # graphics drivers).  replaceDependencies leaves out what is not in the
  # closure, so the 32-bit pieces are only built where they are needed.
  variant =
    p:
    let
      # elogind and eudev as they are in nixpkgs depend (through PAM,
      # util-linux and D-Bus) on the very libraries that are to be replaced,
      # which would make the replacement depend on itself.  So the pieces that
      # go into it come from a package set built without systemd, as in
      # "rebuild" mode.  Only elogind's own closure is built that way: a
      # handful of small packages.
      cleanPkgs = import pkgs.path {
        inherit (p.stdenv.hostPlatform) system;
        inherit (pkgs) config;
        overlays = [
          (import ../pkgs/overlay.nix)
          (import ../pkgs/no-systemd.nix)
        ];
      };

      # libelogind exports what systemd's libsystemd had when elogind was
      # forked, under the same version names, and exists to be used this way.
      # What was added to libsystemd since (the varlink and JSON APIs of 257, a
      # few functions of sd-device, sd-bus, sd-journal) it lacks, and programs
      # that were linked against a recent systemd import some of them even
      # when they never call them.  So the replacement is a library of its
      # own: it needs libelogind, defines the version nodes of the original,
      # and has a stub that reports "not available" (-ENOSYS, or NULL) for each
      # function that libelogind does not have.  The list is made at build
      # time, from the library being replaced.
      libsystemdShim =
        p.runCommandCC "libsystemd-for-elogind"
          {
            nativeBuildInputs = [
              pkgs.buildPackages.binutils-unwrapped
              pkgs.buildPackages.gawk
            ];
            original = "${p.systemdLibs}/lib/libsystemd.so.0";
            elogind = "${cleanPkgs.elogind}/lib/libelogind.so.0";
            elogindDir = "${cleanPkgs.elogind}/lib";
          }
          ''
            mkdir -p $out/lib

            # NAME@VERSION of everything each defines (@@: the default version)
            nm -D --defined-only --with-symbol-versions "$original" | awk 'NF == 3 { print $3 }' | sort -u > real
            nm -D --defined-only --with-symbol-versions "$elogind" | awk 'NF == 3 { print $3 }' | sed 's/@@/@/' | sort -u > have

            # every version node the original has
            grep -o '@@\?LIBSYSTEMD_[0-9]*' real | sed 's/@@\?//' | sort -u > nodes

            # names elogind does not have at all
            sed 's/@@\?.*//' have | sort -u > have-names
            grep '@@' real | sed 's/@@/ /' | sort -u | awk 'NR == FNR { h[$1] = 1; next } !($1 in h)' have-names - > missing
            echo "stubbing $(wc -l < missing) functions libelogind does not have" >&2

            {
              echo '#include <errno.h>'
              while read -r name version; do
                case $name in
                  *_unref|*_ref|*_new|*_get_*) echo "void *$name(void) { return 0; }" ;;
                  *) echo "long $name(void) { return -ENOSYS; }" ;;
                esac
              done < missing
            } > stubs.c

            {
              while read -r node; do
                echo "$node {"
                if grep -q " $node\$" missing; then
                  echo "  global:"
                  awk -v n="$node" '$2 == n { print "    " $1 ";" }' missing
                fi
                echo "};"
              done < nodes
              echo "LIBSYSTEMD_PRIVATE { local: *; };"
            } > exports.map

            $CC -shared -fPIC -O1 -o $out/lib/libsystemd.so.0 stubs.c \
              -Wl,-soname,libsystemd.so.0 \
              -Wl,--version-script=exports.map \
              -Wl,--no-as-needed -L"$elogindDir" -l:libelogind.so.0 \
              -Wl,-rpath,"$elogindDir"
          '';

      libraryLinks = ''
        mkdir -p $out/lib $out/bin
        ln -sf ${libsystemdShim}/lib/libsystemd.so.0 $out/lib/libsystemd.so.0
        ln -sf libsystemd.so.0 $out/lib/libsystemd.so
        ln -sf ${cleanPkgs.eudev}/lib/libudev.so.1 $out/lib/libudev.so.1
        ln -sf libudev.so.1 $out/lib/libudev.so
        ln -sf ${cleanPkgs.eudev}/bin/udevadm $out/bin/udevadm
      '';

      compatLibs =
        original: pkgs.runCommand (sameLengthAs original "elogind-eudev-libs") { } libraryLinks;

      # In place of the systemd package itself: the shim's tools, plus the
      # libraries for whatever was linked against the full package.
      compatSystemd =
        original:
        pkgs.runCommand (sameLengthAs original "systemd-shim") { } ''
          mkdir -p $out
          for entry in ${config.systemd.package}/*; do
            case "$(basename "$entry")" in
              lib|bin) ;;
              *) ln -s "$entry" "$out/" ;;
            esac
          done
          mkdir -p $out/lib $out/bin
          for entry in ${config.systemd.package}/lib/*; do ln -s "$entry" $out/lib/; done
          for entry in ${config.systemd.package}/bin/*; do ln -s "$entry" $out/bin/; done
          ${libraryLinks}
        '';
    in
    {
      inherit cleanPkgs libsystemdShim;
      replacements = [
        {
          oldDependency = p.systemdLibs;
          newDependency = compatLibs p.systemdLibs;
        }
        {
          oldDependency = p.systemdMinimal;
          newDependency = compatLibs p.systemdMinimal;
        }
        {
          oldDependency = p.systemd;
          newDependency = compatSystemd p.systemd;
        }
      ]
      # What headers and .pc files of systemd packages' dev outputs refer to
      # is a path of the store too; nothing of them is wanted either.
      ++ lib.concatMap (
        s:
        lib.optional (s ? dev) {
          oldDependency = s.dev;
          newDependency = devStub s.dev;
        }
      ) [
        p.systemd
        p.systemdMinimal
        p.systemdLibs
      ]
      # And the rest of their outputs (man pages: a package that lists
      # systemd's in its own brought the real one into ndppd's and rstp's
      # systems): empty.
      ++ lib.concatMap (
        s:
        map (o: {
          oldDependency = s.${o};
          newDependency = pkgs.runCommand (sameLengthAs s.${o} "systemd-shim-${o}") { } "mkdir -p $out";
        }) (lib.filter (o: o != "out" && o != "dev" && o != "lib") (s.outputs or [ ]))
      ) [
        p.systemd
        p.systemdMinimal
        p.systemdLibs
      ];
    };

  # The "dev" outputs: headers and pkg-config files, which a system has no use
  # for but may still mention.  The stand-in is empty but for a systemd.pc.
  devStub =
    original:
    pkgs.runCommand (sameLengthAs original "systemd-shim-dev") { } ''
      mkdir -p $out/lib/pkgconfig
      ln -s ${config.systemd.package}/share/pkgconfig/systemd.pc $out/lib/pkgconfig/systemd.pc
    '';

  native = variant pkgs;
  inherit (native) cleanPkgs libsystemdShim;

  # Every symbol a program imports from libsystemd or libudev has to exist in
  # what takes their place: such programs are linked with immediate binding
  # and would not even start otherwise.  The text is empty if all is well.
  symbolCheck =
    unreplaced:
    pkgs.runCommand "systemd-library-replacement-check"
      {
        nativeBuildInputs = [
          pkgs.buildPackages.binutils-unwrapped
          pkgs.buildPackages.findutils
          pkgs.buildPackages.gnugrep
          pkgs.buildPackages.gawk
        ];
        closure = pkgs.closureInfo { rootPaths = [ unreplaced ]; };
        elogindLib = "${cleanPkgs.elogind}/lib/libelogind.so.0";
        shimLib = "${libsystemdShim}/lib/libsystemd.so.0";
        eudevLib = "${cleanPkgs.eudev}/lib/libudev.so.1";
        preferLocalBuild = true;
      }
      ''
        { nm -D --defined-only --with-symbol-versions "$elogindLib"
          nm -D --defined-only --with-symbol-versions "$shimLib"; } \
          | awk 'NF == 3 { sub(/@@/, "@", $3); print $3; sub(/@.*/, "", $3); print $3 }' | sort -u > have-sd
        nm -D --defined-only --with-symbol-versions "$eudevLib" \
          | awk '{ sub(/@@/, "@", $3); print $3; sub(/@.*/, "", $3); print $3 }' | sort -u > have-udev

        cat > scan <<'EOF'
        for file; do
          needed=$(readelf -d "$file" 2>/dev/null | grep -E 'NEEDED.*lib(systemd|udev)\.so') || continue
          nm -D --undefined-only --with-symbol-versions "$file" 2>/dev/null | awk '{ print $2 }' > "$TMPDIR/want.$$"
          case $needed in
            *libsystemd*)
              grep -E '^sd_' "$TMPDIR/want.$$" | sort -u | comm -23 - have-sd | sed "s|^|$file: |" ;;
          esac
          case $needed in
            *libudev*)
              grep -E '^udev_' "$TMPDIR/want.$$" | sort -u | comm -23 - have-udev | sed "s|^|$file: |" ;;
          esac
        done
        EOF
        sed -i 's/^        //' scan

        while read -r path; do
          [ -d "$path" ] && find "$path" -type f \( -perm -u+x -o -name '*.so*' \) -print0
        done < $closure/store-paths | xargs -0 -r -n 64 -P 8 sh scan > problems || true

        if [ -s problems ]; then
          {
            echo "These programs need symbols that elogind's libsystemd and eudev's libudev do not provide:"
            sort -u problems | head -n 100
            echo
            echo "Build those packages without systemd (s6.systemdPackages = \"rebuild\", or an"
            echo "overlay for just them), or keep the systemd libraries (\"keep\")."
          } > $out
        else
          : > $out
        fi
      '';

  # With replacements the closure that must be free of systemd is the
  # replaced one, so system.forbiddenDependenciesRegexes is enforced here.
  forbiddenCheck =
    replaced:
    pkgs.runCommand "forbidden-dependencies-check"
      {
        closure = pkgs.closureInfo { rootPaths = [ replaced ]; };
        regexes = config.system.forbiddenDependenciesRegexes;
        preferLocalBuild = true;
      }
      ''
        set -f
        : > found
        for regex in $regexes; do
          grep -E -- "$regex" $closure/store-paths >> found || true
        done
        if [ -s found ]; then
          { echo "The system closure contains the following disallowed paths:"; cat found; } > $out
        else
          : > $out
        fi
      '';
in

{
  # A service with confinement.enable runs in a root made of the store paths
  # of its closure, listed when the system is built: before the
  # replacements.  Where systemd's libraries were, the list ends up naming
  # what replaces them, but not what that is made of (the libsystemd shim,
  # libelogind, eudev), and murmur could not find libsystemd.so.0.  So that
  # comes along.
  options.systemd.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config = lib.mkIf (mode == "replace" && config.confinement.enable) {
            confinement.packages = map (r: r.newDependency) native.replacements;
          };
        }
      )
    );
  };

  options.s6.systemdPackages = lib.mkOption {
    type = lib.types.enum [
      "rebuild"
      "replace"
      "keep"
    ];
    default = "replace";
    description = ''
      What to do about the systemd that packages bring along.

      `"replace"` (the default)
      : Take packages from the binary cache as they are and swap the
        libraries underneath them: libsystemd becomes elogind's libelogind
        (same symbols, same versions), libudev becomes eudev's.  Nothing of
        systemd is in the closure and nothing has to be compiled, but the
        programs still contain their systemd code paths.  The system build
        fails if a program needs a symbol the replacements lack.  The swap
        is done by `system.replaceDependencies`, so evaluating the
        configuration builds the system first (import from derivation).

      `"rebuild"`
      : Build the package set without systemd support
        (../pkgs/no-systemd.nix).  Nothing of systemd is in the closure, and
        nothing was compiled against it.  The binary cache has none of these
        variants, so everything whose build involves systemd, D-Bus, udev or
        PAM is compiled locally: about twenty minutes for a server, hours
        for a desktop, and packages that insist on systemd have to be
        dealt with one by one.  The only mode that changes packages.

      `"keep"`
      : Do nothing.  systemd does not run, but its libraries, and in places
        the whole package, stay in the closure.
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf (mode == "rebuild") {
      nixpkgs.overlays = [ (import ../pkgs/no-systemd.nix) ];
    })

    (lib.mkIf (mode == "replace") {
      system.replaceDependencies = {
        replacements =
          native.replacements
          ++ lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
            variant pkgs.pkgsi686Linux
          ).replacements;
        preChecks = [ symbolCheck ];
        postChecks = [ forbiddenCheck ];
      };
    })

    # The same for AppArmor: a profile's rules come from the closure of the
    # program before the replacements (apparmorRulesFromClosure), and allow
    # the paths that the replacements take the place of, not the libraries
    # behind them.  murmur's profile kept it from opening libsystemd.so.0
    # (EACCES, "apparmor=DENIED" in the kernel log).  Every profile includes
    # abstractions/base: there they are allowed for all.
    (lib.mkIf (mode == "replace" && config.security.apparmor.enable) {
      security.apparmor.includes."abstractions/base" = lib.mkAfter ''
        # what replaces systemd's libraries (NixithOS, s6.systemdPackages = "replace")
        include "${
          pkgs.apparmorRulesFromClosure { name = "systemd-replacements"; } (
            map (r: r.newDependency) config.system.replaceDependencies.replacements
          )
        }"
      '';
    })

    (lib.mkIf (mode != "keep") {
      # Fail the build, rather than quietly ship it, if systemd finds a way in.
      system.forbiddenDependenciesRegexes = [ "-systemd(-minimal|-minimal-libs)?-[0-9]" ];
    })
  ];
}
