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
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

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

      # One module list per devShell: `nix develop .#go`, `nix develop .#javascript`,
      # … Every `enable` switch of the area is turned on, so each of these also
      # proves the module builds at all (see `checks`). `delve`, `lsp`, `nodejs`
      # and the language-server switches already default to true and are
      # deliberately not repeated here.
      featureModules = {
        go = [ { languages.go.enable = true; } ];
        javascript = [
          {
            languages.javascript = {
              enable = true;
              corepack.enable = true;
              npm.enable = true;
              pnpm.enable = true;
              yarn.enable = true;
              bun.enable = true;
            };
          }
        ];
        python = [
          {
            languages.python = {
              enable = true;
              uv.enable = true;
            };
          }
        ];
        java = [
          {
            languages.java = {
              enable = true;
              maven.enable = true;
              gradle.enable = true;
            };
          }
        ];
        dart = [ { languages.dart.enable = true; } ];
        android = [ { android.enable = true; } ];
        arduino = [ { arduino.enable = true; } ];
        espidf = [ { espidf.enable = true; } ];
      };

      shellNames = builtins.attrNames featureModules;

      # Printed by `nix develop` without an attribute; derived from
      # `featureModules`, so it cannot go stale.
      helpText = lib.concatMapStringsSep "\n" (name: "  nix develop .#${name}") shellNames;
    in
    {
      devShells = forAllSystems (
        system:
        let
          shellFor =
            modules:
            self.lib.mkShell {
              inherit inputs system;
              modules = modules;
            };
        in
        lib.mapAttrs (_: shellFor) featureModules
        // {
          # `nix develop` on its own builds a shell that only says what to pick.
          default = shellFor [
            {
              name = "aurora-devshell-help";
              enterShell = ''
                echo "Aurora development shells:"
                echo
                echo ${lib.escapeShellArg helpText}
                echo
                echo "Enter one with: nix develop .#<name>"
              '';
            }
          ];
        }
      );

      # `checks` is one `ciDerivation` per devShell: `nix flake check` (and CI)
      # builds the shell's closure and its activation script.
      checks = forAllSystems (system: lib.mapAttrs (_: shell: shell.ci) self.devShells.${system});

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
