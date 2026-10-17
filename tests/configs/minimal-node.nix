# What every test node has in common.
{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/minimal.nix") ];
}
