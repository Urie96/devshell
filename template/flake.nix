{
  inputs = {
    devshell.url = "github:urie96/devshell";
    nixpkgs.follows = "devshell/nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      devshell,
      ...
    }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs, system }:
        {
          default = devshell.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                espidf.enable = true;
              }
            ];
          };
        }
      );
    };
}
