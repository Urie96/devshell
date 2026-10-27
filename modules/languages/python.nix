{
  pkgs,
  config,
  lib,
  ...
}:

let
  cfg = config.languages.python;
in
{
  options.languages.python = {
    enable = lib.mkEnableOption "tools for Python development";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3;
      defaultText = lib.literalExpression "pkgs.python3";
      description = "The Python package to use.";
    };

    # version = lib.mkOption {
    #   type = lib.types.nullOr lib.types.str;
    #   default = null;
    #   description = ''
    #     The Python version to use.
    #   '';
    #   example = "3.11 or 3.11.2";
    # };

    uv = {
      enable = lib.mkEnableOption "uv";
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.uv;
        defaultText = lib.literalExpression "pkgs.uv";
        description = "The uv package to use.";
      };
    };

    lsp = {
      enable = lib.mkEnableOption "Python Language Server" // {
        default = true;
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.pyright;
        defaultText = lib.literalExpression "pkgs.pyright";
        description = "The Python language server package to use.";
      };
    };

  };

  config = lib.mkIf cfg.enable {
    packages = [
      cfg.package
    ]
    ++ (lib.optional cfg.uv.enable cfg.uv.package)
    ++ lib.optional cfg.lsp.enable cfg.lsp.package;

    env = lib.optionalAttrs cfg.uv.enable {
      # Force uv to use the Nix-provided Python and never download its own
      UV_PYTHON_DOWNLOADS = "never";
      UV_PYTHON_PREFERENCE = "only-system";
      # Do not set UV_PYTHON here. It overrides VIRTUAL_ENV resolution
      # and causes `uv pip install` to target the immutable Nix store
      # prefix instead of the venv. See https://github.com/cachix/devenv/issues/2663
    };
  };
}
