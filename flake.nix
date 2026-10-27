{
  description = "Aurora development environment";

  nixConfig = {
    # extra-substituters = [
    # ];
    # extra-trusted-public-keys = [
    # ];
  };

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";

    multiverse.url = "github:fzakaria/nixpkgs-multiverse";
  };

  outputs =
    {
      self,
      nixpkgs,
      multiverse,
      ...
    }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };

          base = self.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                languages.go.enable = true;
                languages.go.version = "1.24.6";
                android.enable = true;
              }
            ];
          };
        in
        {
          default = base;
        }
      );

      lib = {
        mkConfig = args: (self.lib.mkEval args).config;

        mkEval =
          args@{
            pkgs,
            inputs ? [ ],
            modules,
            lib ? pkgs.lib,
          }:
          let
            modules = [
              (./modules/top-level.nix)
              {
                _module.args =
                  let
                    system = pkgs.stdenv.hostPlatform.system;
                  in
                  {
                    inherit pkgs inputs system;
                    multiverse = multiverse.multiverse.${system};
                  };
              }
            ]
            ++ args.modules;

            project = lib.evalModules {
              class = "devshell";
              inherit modules;
            };
          in
          project;

        mkShell =
          args:
          let
            config = self.lib.mkConfig args;
            extend = module: self.lib.mkShell (args // { modules = (args.modules or [ ]) ++ [ module ]; });
          in
          config.shell
          // {
            inherit config extend;
            ci = config.ciDerivation;
            activation = config.activation;
          };
      };

      templates = {
        default = {
          path = ./template;
          description = "Devenv template";
        };
      };
    };
}
