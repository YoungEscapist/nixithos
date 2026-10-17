# What `nixith` (../pkgs/nixith) builds: a system out of a configuration, the
# whole of it, or only some parts of it with the rest as it is in the running
# system.
#
# Every system built this way says what it was built from, in
# nixith/source.json of the system (and the sources themselves are in its
# closure):
#
#   base     the configuration: a copy of its directory (/etc/nixith), or a
#            flake, with the tree and nixpkgs it was evaluated with
#   layers   parts rebuilt on their own afterwards, latest last: a copy of the
#            configuration at that time and the options taken from it
#
# A partial rebuild (`nixith switch --only services.nginx`) evaluates the base
# of the running system as it was, and adds one more layer: the definitions of
# the options under the given paths, as the configuration has them now, in
# place of the ones of the base and of older layers.  Whatever is not under
# those paths evaluates to what the running system has, so it is the same
# store paths and switch-to-configuration leaves it alone.  A full build
# starts over with a new base and no layers.
{
  # the configuration to build: the file (`configuration`) - its whole
  # directory is copied, for later partial rebuilds - or a flake ("ref#name")
  configuration ? null,
  flake ? null,
  # option paths ("services.nginx", "environment.systemPackages"): build only
  # these out of the configuration, the rest as in `previous`
  only ? [ ],
  # source.json of the running system (needed with `only`)
  previous ? null,
  # this tree and the nixpkgs under it, as the running system has them
  tree,
  nixpkgs,
  # copy `tree` and `nixpkgs` into the store being built in (nixith install,
  # which builds in the store of the new system), not just refer to them
  copySources ? false,
  system ? builtins.currentSystem,
}:

let
  lib = import "${nixpkgs}/lib";
  inherit (lib)
    any
    attrByPath
    concatMap
    concatStringsSep
    drop
    filter
    imap0
    isOption
    length
    splitString
    take
    ;

  storeDir =
    p: name:
    if copySources then
      "${builtins.path {
        path = p;
        inherit name;
      }}"
    else
      builtins.storePath p;

  onlyList = if builtins.isList only then only else filter (p: p != "") (splitString "," only);

  # --- sources --------------------------------------------------------------

  fileSource =
    file:
    let
      dir = dirOf file;
    in
    {
      kind = "file";
      config = "${builtins.path {
        name = "nixith-config";
        path = dir;
        # (not the repository, links to builds, editor and other hidden files)
        filter =
          path: type:
          let
            base = baseNameOf path;
          in
          !(lib.hasPrefix "." base || lib.hasPrefix "result" base);
      }}";
      file = baseNameOf file;
      tree = storeDir tree "nixithos";
      nixpkgs = storeDir nixpkgs "source";
    };

  flakeSource =
    ref:
    let
      m = builtins.match "([^#]*)#(.*)" ref;
      f = builtins.getFlake (builtins.elemAt m 0);
    in
    if m == null then
      throw "nixith: a flake is given as ref#name"
    else
      {
        kind = "flake";
        # the flake as it is now, locked
        ref = "path:${f.outPath}?narHash=${f.narHash}";
        name = builtins.elemAt m 1;
      };

  # a source read back from source.json: the store paths in it are strings
  # without context; they get it back so that a new source.json refers to
  # them again
  restore =
    src:
    if src.kind == "file" then
      src
      // {
        config = builtins.storePath src.config;
        tree = builtins.storePath src.tree;
        nixpkgs = builtins.storePath src.nixpkgs;
      }
    else
      let
        m = builtins.match "path:([^?]*)(\\?.*)" src.ref;
      in
      src // { ref = "path:${builtins.storePath (builtins.elemAt m 0)}${builtins.elemAt m 1}"; };

  describe =
    src: if src.kind == "file" then "${src.config}/${src.file}" else "${src.ref}#${src.name}";

  evalSource =
    src: modules:
    if src.kind == "file" then
      import "${src.tree}/lib/eval-config.nix" {
        nixpkgs = src.nixpkgs;
        lib = import "${src.nixpkgs}/lib";
        inherit system;
        modules = [ "${src.config}/${src.file}" ] ++ modules;
      }
    else
      let
        f = builtins.getFlake src.ref;
        sys =
          f.nixithConfigurations.${src.name} or f.nixosConfigurations.${src.name}
            or (throw "nixith: the flake has no nixithConfigurations.${src.name} (nor nixosConfigurations.${src.name})");
      in
      sys.extendModules { inherit modules; };

  source =
    if flake != null then
      flakeSource flake
    else if configuration != null then
      fileSource configuration
    else
      throw "nixith: no configuration given";

  # --- what to build ---------------------------------------------------------

  locOf = splitString ".";
  # whether `path` is `prefix` or under it
  under = prefix: loc: take (length (locOf prefix)) loc == locOf prefix;

  previousMeta =
    if previous == null then
      throw ''
        nixith: the running system does not say what it was built from (it was
        not built by nixith, or before nixith could rebuild parts), so there is
        nothing to keep the rest from.  Build it whole once: nixith switch''
    else
      # (without the context of the store paths in it, which fromJSON refuses;
      # `restore` gives it back)
      builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile previous));

  meta =
    if onlyList == [ ] then
      {
        base = source;
        layers = [ ];
      }
    else
      {
        base = restore previousMeta.base;
        layers =
          # what the new layer covers is no longer taken from older ones
          filter (l: l.only != [ ]) (
            map (
              l:
              l
              // {
                source = restore l.source;
                only = filter (p: !any (q: under q (locOf p)) onlyList) l.only;
              }
            ) previousMeta.layers
          )
          ++ [
            {
              inherit source;
              only = onlyList;
            }
          ];
      };

  # the options at `path` in an evaluated configuration: the option there, or
  # all options under it
  optionsAt =
    ev: path:
    let
      loc = locOf path;
      found = attrByPath loc null ev.options;
      # (the longest prefix that is an option, for the message)
      inside = lib.findFirst (n: isOption (attrByPath (take n loc) null ev.options)) null (
        lib.reverseList (lib.range 1 (length loc - 1))
      );
    in
    if found != null && isOption found then
      [ found ]
    else if found != null && builtins.isAttrs found then
      lib.collect isOption found
    else if inside != null then
      throw "nixith: ${path} is inside the option ${concatStringsSep "." (take inside loc)}; rebuild that one (--only ${concatStringsSep "." (take inside loc)})"
    else
      throw "nixith: ${path}: no such option or group of options";

  # A layer as a module: each option under its paths (and not under those of
  # a later layer) defined as the layer's configuration defines it, above
  # every definition of the base.  `definitions` are what the option's value
  # is merged from (after mkIf, mkOverride and ordering, before `apply`), the
  # default when nothing defines it - so an option no longer set goes back to
  # its default.
  layerModule =
    i: layer:
    let
      ev = evalSource layer.source [ ];
      later = concatMap (l: l.only) (drop (i + 1) meta.layers);
      options = builtins.attrValues (
        builtins.listToAttrs (
          map (o: lib.nameValuePair (lib.showOption o.loc) o) (concatMap (optionsAt ev) layer.only)
        )
      );
      taken = filter (o: !(o.readOnly or false) && !any (p: under p o.loc) later) options;
    in
    {
      _file = "nixith: ${concatStringsSep ", " layer.only} from ${describe layer.source}";
      config = lib.mkMerge (
        map (o: lib.setAttrByPath o.loc (lib.mkMerge (map (lib.mkOverride 1) o.definitions))) taken
      );
    };

  metaModule =
    { pkgs, ... }:
    {
      _file = "nixith";
      system.systemBuilderCommands = ''
        mkdir -p $out/nixith
        ln -s ${pkgs.writeText "nixith-source.json" (builtins.toJSON meta)} $out/nixith/source.json
      '';
    };

  final = evalSource meta.base (imap0 layerModule meta.layers ++ [ metaModule ]);
in
{
  inherit (final) config options pkgs;
  inherit meta;
  system = final.config.system.build.toplevel;
}
