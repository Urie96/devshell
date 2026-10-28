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
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # The pkgs every consumer gets unless it passes its own, so that
      # `mkEval { system = ...; }` behaves exactly like `mkEval { pkgs = ...; }`
      # with the pkgs from `devShells`.
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };
    in
    {
      devShells = forAllSystems (system: {
        default = self.lib.mkShell {
          inherit inputs system;
          modules = [
            {
              languages.go = {
                version = "1.24.6";
                enable = true;
              };
              # espidf.enable = true;
            }
          ];
        };
      });

      lib = {
        mkConfig = args: (self.lib.mkEval args).config;

        mkEval =
          args:
          let
            # `pkgs` and `system` are interchangeable, exactly one of them has
            # to be passed (`pkgs` wins if both are given and agree).
            pkgs =
              if args ? pkgs && args.pkgs != null then
                if args ? system && args.system != null && args.system != args.pkgs.stdenv.hostPlatform.system then
                  throw "mkEval: `system` is `${args.system}` but `pkgs` is for `${args.pkgs.stdenv.hostPlatform.system}`"
                else
                  args.pkgs
              else if args ? system && args.system != null then
                mkPkgs args.system
              else
                throw "mkEval: pass either `pkgs` or `system`";

            lib = args.lib or pkgs.lib;
            inputs = args.inputs or { };
            # Fallback for inputs the flake does not declare, see
            # `config.lib.getInput`. Evaluated lazily, so the file is only read
            # when an input is actually resolved through niv.
            niv = args.niv or (import ./nix/sources.nix { inherit pkgs; });

            modules = [
              (./modules/top-level.nix)
              ({ config, ... }: {
                _module.args =
                  let
                    system = pkgs.stdenv.hostPlatform.system;
                  in
                  {
                    inherit inputs niv system;
                    pkgs = pkgs.appendOverlays (config.overlays or [ ]);
                  };
              })
            ]
            ++ args.modules;
          in
          lib.evalModules {
            class = "devshell";
            inherit modules;
          };

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
