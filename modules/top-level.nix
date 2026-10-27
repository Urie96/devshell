{
  config,
  pkgs,
  lib,
  ...
}:
{
  options =
    let
      types = lib.types;
    in
    {
      env = lib.mkOption {
        type = types.submodule {
          freeformType = types.lazyAttrsOf types.anything;
        };
        description = "Environment variables to be exposed inside the developer environment.";
        default = { };
      };

      name = lib.mkOption {
        type = types.nullOr types.str;
        description = "Name of the project.";
        default = "devenv-shell";
      };

      stdenv = lib.mkOption {
        type = types.package;
        description = "The stdenv to use for the developer environment.";
        default = pkgs.stdenvNoCC;
        defaultText = lib.literalExpression "pkgs.stdenv";
      };

      enterShell = lib.mkOption {
        type = types.lines;
        description = "Bash code to execute when entering the shell.";
        default = "";
      };

      packages = lib.mkOption {
        type = types.listOf types.package;
        description = "A list of packages to expose inside the developer environment. Search available packages using ``devenv search NAME``.";
        default = [ ];
      };

      root = lib.mkOption {
        type = types.nullOr types.str;
      };

      shell = lib.mkOption {
        type = types.package;
        internal = true;
      };

      ci = lib.mkOption {
        type = types.listOf types.package;
        internal = true;
      };

      ciDerivation = lib.mkOption {
        type = types.package;
        internal = true;
      };

      activation = lib.mkOption {
        type = types.package;
        internal = true;
      };
    };

  imports =
    let
      listEntries = path: map (name: path + "/${name}") (builtins.attrNames (builtins.readDir path));
    in
    [ ] ++ (listEntries ./languages) ++ (listEntries ./integrations);

  config = {
    enterShell = lib.mkBefore ''
      export DEVSHELL_ROOT=${if config.root != null then config.root else "$PWD"}
    '';

    shell = (pkgs.mkShell.override { stdenv = config.stdenv; }) (
      {
        inherit (config) packages;
        shellHook = config.enterShell;
      }
      // config.env
    );

    ci = [ config.shell ];
    ciDerivation = pkgs.runCommand "ci" { } "echo ${toString config.ci} > $out";

    activation =
      let
        # Same derivation nix would build for `nix print-dev-env`, except that it is
        # reachable from the flake. Empty $out would be a valid JSON document, so the
        # output is a file rather than a directory.
        envJson = config.shell.overrideAttrs (_: {
          name = "${config.name}-json";
          # No phases are run (get-env.sh is the whole builder), so there is nothing
          # to fix up either.
          builder = lib.getExe pkgs.bash;
          args = [ ./activation/get-env.sh ];
        });
      in
      pkgs.runCommandLocal config.name
        {
          # Referenced by absolute path below; deliberately not buildInputs, since
          # their bin/ directories would show up in the rendered PATH.
          inherit envJson;
          dontFixup = true;
          meta.description = "Activation scripts for the ${config.name} devShell";
        }
        ''
          # direnv loads the environment with bash, so bash is all we render.
          # $out *is* the script (`source /nix/store/...-aurora-devshell-env`), so
          # callers never have to append a path component to the store path.
          ${pkgs.python3.interpreter} ${./activation/devshell-bash.py} $envJson \
            > $out
        '';
  };
}
