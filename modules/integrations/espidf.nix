{
  pkgs,
  config,
  ...
}:
let
  esp-dev = config.lib.getInput "nixpkgs-esp-dev";
in
{
  config = {
    packages = [
      esp-dev.packages.${pkgs.stdenv.hostPlatform.system}.esp-idf-esp32c3
    ];
  };
}
