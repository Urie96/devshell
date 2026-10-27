{
  pkgs,
  config,
  lib,
  ...
}:

let
  cfg = config.languages.javascript;

  pnpmArgs = lib.functionArgs pkgs.pnpm.override;

  pnpmPackage =
    if builtins.hasAttr "nodejs-slim" pnpmArgs then
      pkgs.pnpm.override { nodejs-slim = cfg.package; }
    else
      pkgs.pnpm.override { nodejs = cfg.package; };
in
{
  options.languages.javascript = {
    enable = lib.mkEnableOption "tools for JavaScript development";

    directory = lib.mkOption {
      type = lib.types.str;
      default = config.devenv.root;
      defaultText = lib.literalExpression "config.devenv.root";
      description = ''
        The JavaScript project's root directory. Defaults to the root of the devenv project.
        Can be an absolute path or one relative to the root of the devenv project.
      '';
      example = "./directory";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nodejs-slim;
      defaultText = lib.literalExpression "pkgs.nodejs-slim";
      description = "The Node.js package to use.";
    };

    nodejs = {
      enable = lib.mkEnableOption "Node.js runtime" // {
        default = true;
      };
    };

    corepack = {
      enable = lib.mkEnableOption "wrappers for npm, pnpm and Yarn via Node.js Corepack";
    };

    npm = {
      enable = lib.mkEnableOption "install npm";
      package = lib.mkOption {
        type = lib.types.package;
        default =
          # nixpkgs 26.05+: nodejs-slim has an npm output
          if builtins.elem "npm" (cfg.package.outputs or [ ]) then
            lib.getOutput "npm" cfg.package
          # older nixpkgs: enableNpm override
          else if cfg.package ? override && lib.functionArgs cfg.package.override ? enableNpm then
            cfg.package.override { enableNpm = true; }
          else
            cfg.package;
        defaultText = lib.literalExpression "languages.javascript.package";
        description = "The npm package to use. Defaults to the npm output of the javascript package.";
      };
    };

    pnpm = {
      enable = lib.mkEnableOption "install pnpm";
      package = lib.mkOption {
        type = lib.types.package;
        default = pnpmPackage;
        defaultText = lib.literalExpression "pkgs.pnpm";
        description = "The pnpm package to use.";
      };
    };

    yarn = {
      enable = lib.mkEnableOption "install yarn";
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.yarn.override {
          nodejs = cfg.package;
        };
        defaultText = lib.literalExpression "pkgs.yarn";
        description = "The yarn package to use.";
      };
    };

    bun = {
      enable = lib.mkEnableOption "install bun";
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bun;
        defaultText = lib.literalExpression "pkgs.bun";
        description = "The bun package to use.";
      };
    };

    lsp = {
      enable = lib.mkEnableOption "TypeScript Language Server for JavaScript" // {
        default = true;
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.typescript-language-server;
        defaultText = lib.literalExpression "pkgs.typescript-language-server";
        description = "The TypeScript/JavaScript language server package to use.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    packages =
      let
        # On nixpkgs 26.05+, nodejs-slim has a corepack output.
        corepack = cfg.package.corepack or cfg.package;
      in
      lib.optional cfg.nodejs.enable cfg.package
      ++ lib.optional cfg.npm.enable cfg.npm.package
      ++ lib.optional cfg.pnpm.enable (cfg.pnpm.package)
      ++ lib.optional cfg.yarn.enable (cfg.yarn.package.override { nodejs = cfg.package; })
      ++ lib.optional cfg.bun.enable (cfg.bun.package)
      ++ lib.optionals cfg.corepack.enable [
        corepack
        (pkgs.runCommand "corepack-enable" { } ''
          mkdir -p $out/bin
          ${corepack}/bin/corepack enable --install-directory $out/bin
        '')
      ]
      ++ lib.optional cfg.lsp.enable cfg.lsp.package;

  };
}
