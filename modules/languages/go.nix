{
  pkgs,
  config,
  multiverse,
  lib,
  ...
}:
let
  cfg = config.languages.go;

  pinnedPkgs =
    if cfg.version != null then (multiverse.at (multiverse.revOf "go" cfg.version)) else pkgs;
in
{
  options.languages.go = {
    enable = lib.mkEnableOption "tools for Go development";

    package = lib.mkOption {
      type = lib.types.package;
      default = pinnedPkgs.go;
      defaultText = lib.literalExpression "pkgs.go";
      description = "The Go package to use.";
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The Go version to use.";
      example = "1.22.0";
    };

    delve = {
      enable = lib.mkEnableOption "Delve debugger" // {
        default = true;
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pinnedPkgs.delve;
        defaultText = lib.literalExpression "pkgs.delve";
        description = "The Delve package to use. Override this to customize the build, e.g. to disable tests.";
      };
    };

    lsp = {
      enable = lib.mkEnableOption "Go Language Server" // {
        default = true;
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pinnedPkgs.gopls;
        defaultText = lib.literalExpression "pkgs.gopls";
        description = "The Go language server package to use.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [
      cfg.package
    ]
    ++ lib.optional cfg.delve.enable cfg.delve.package
    ++ (with pinnedPkgs; [
      # vscode-go expects all tool compiled with the same used go version, see: https://github.com/golang/vscode-go/blob/72249dc940e5b6ec97b08e6690a5f042644e2bb5/src/goInstallTools.ts#L721
      gotools
      gomodifytags
      impl
      go-tools
      gotests
      protoc-gen-go
    ])
    ++ lib.optional cfg.lsp.enable cfg.lsp.package;

    env = {
      GOROOT = cfg.package + "/share/go/";
      GOTOOLCHAIN = "local";
    };

    enterShell = ''
      export PATH=$GOPATH/bin:$PATH
    '';
  };
}
