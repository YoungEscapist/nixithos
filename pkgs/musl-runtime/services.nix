# A deliberately small native dinit service interface. Unknown settings are errors.
{ lib, pkgs, runtime, services }:
let
  fail = message: throw "musl services: ${message}";
  ensure = condition: message: if condition then true else fail message;
  names = builtins.attrNames services;
  validName = name: builtins.isString name && builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" name != null && name != "boot";
  isAbsolute = value: builtins.isString value && lib.hasPrefix "/" value;
  fields = [ "command" "type" "dependsOn" "after" "restart" "environment" "workingDirectory" "user" "logFile" "stopSignal" "stopTimeout" ];
  normalize = name:
    let
      raw = services.${name};
      extra = if builtins.isAttrs raw then builtins.filter (key: !(builtins.elem key fields)) (builtins.attrNames raw) else [];
      s = {
        type = "process";
        dependsOn = [];
        after = [];
        restart = false;
        environment = {};
        workingDirectory = null;
        user = null;
        logFile = null;
        stopSignal = "TERM";
        stopTimeout = 10;
      } // raw;
      depsOk = deps: builtins.isList deps && builtins.all (dep: builtins.isString dep && builtins.elem dep names && dep != name) deps;
      envOk = builtins.isAttrs s.environment && builtins.all (key: builtins.match "[A-Za-z_][A-Za-z0-9_]*" key != null && builtins.isString s.environment.${key}) (builtins.attrNames s.environment);
      checks = [
        (ensure (validName name) "invalid or reserved service name '${name}'")
        (ensure (builtins.isAttrs raw) "${name}: expected an attribute set")
        (ensure (extra == []) "${name}: unsupported settings: ${lib.concatStringsSep ", " extra}")
        (ensure (s ? command && builtins.isList s.command && s.command != [] && builtins.all builtins.isString s.command && isAbsolute (builtins.head s.command)) "${name}: command must be a nonempty list of strings starting with an absolute path")
        (ensure (builtins.elem s.type [ "process" "scripted" ]) "${name}: unsupported type")
        (ensure (depsOk s.dependsOn && depsOk s.after) "${name}: dependencies must be lists of other declared services")
        (ensure (builtins.isBool s.restart && (s.type != "scripted" || !s.restart)) "${name}: restart must be boolean and is unsupported for scripted services")
        (ensure (builtins.elem s.stopSignal [ "TERM" "HUP" "INT" "KILL" "QUIT" ]) "${name}: unsupported stopSignal")
        (ensure (builtins.isInt s.stopTimeout && s.stopTimeout > 0) "${name}: stopTimeout must be a positive integer")
        (ensure envOk "${name}: environment must contain valid variable names and string values")
        (ensure (s.workingDirectory == null || isAbsolute s.workingDirectory) "${name}: workingDirectory must be an absolute path")
        (ensure (s.logFile == null || isAbsolute s.logFile) "${name}: logFile must be an absolute path")
        (ensure (s.user == null || (builtins.isString s.user && builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" s.user != null)) "${name}: invalid user")
      ];
    in builtins.deepSeq checks s;
  normalized = builtins.listToAttrs (map (name: { inherit name; value = normalize name; }) names);
  checkCycle = path: name:
    if builtins.elem name path then fail "dependency cycle: ${lib.concatStringsSep " -> " (path ++ [ name ])}"
    else builtins.deepSeq (map (checkCycle (path ++ [ name ])) (normalized.${name}.dependsOn ++ normalized.${name}.after)) true;
  checks = builtins.deepSeq normalized (map (checkCycle []) names);
  quote = lib.escapeShellArg;
  wrapper = name:
    let
      s = normalized.${name};
      envArgs = lib.mapAttrsToList (key: value: quote "${key}=${value}") s.environment;
    in pkgs.writeTextFile {
      name = "musl-service-${name}";
      executable = true;
      text = ''
        #!${pkgs.busybox}/bin/ash
        set -eu
        ${lib.optionalString (s.workingDirectory != null) "cd -- ${quote s.workingDirectory}"}
        ${lib.optionalString (s.logFile != null) "exec >>${quote s.logFile} 2>&1"}
        exec ${pkgs.busybox}/bin/busybox env -i ${quote "PATH=${pkgs.busybox}/bin"} ${lib.concatStringsSep " " envArgs} ${lib.concatMapStringsSep " " quote s.command}
      '';
    };
  wrappers = builtins.listToAttrs (map (name: { inherit name; value = wrapper name; }) names);
  description = name:
    let s = normalized.${name}; in pkgs.writeText "dinit-${name}" (''
      type = ${s.type}
      command = ${wrappers.${name}}
      restart = ${if s.restart then "true" else "false"}
      term-signal = ${s.stopSignal}
      stop-timeout = ${toString s.stopTimeout}
      options = shares-console
    '' + lib.optionalString s.restart ''
      restart-delay = 1
      restart-limit-count = 0
    '' + lib.optionalString (s.user != null) "run-as = ${s.user}\n"
       + lib.concatMapStrings (dep: "depends-on: ${dep}\n") s.dependsOn
       + lib.concatMapStrings (dep: "after: ${dep}\n") s.after);
  boot = pkgs.writeText "dinit-boot" ("type = internal\n" + lib.concatMapStrings (name: "waits-for: ${name}\n") names);
in
builtins.deepSeq checks (pkgs.runCommand "musl-dinit-services" {} (''
  mkdir -p "$out/etc/dinit.d" "$out/etc/unit-runtime/services"
  ln -s ${boot} "$out/etc/dinit.d/boot"
'' + lib.concatMapStrings (name: ''
  ln -s ${description name} "$out/etc/dinit.d/${name}"
  ln -s ${wrappers.${name}} "$out/etc/unit-runtime/services/${name}"
'') names))
