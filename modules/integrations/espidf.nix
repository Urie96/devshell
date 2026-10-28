{
  pkgs,
  config,
  lib,
  ...
}:
let
  cfg = config.espidf;

  esp-dev = config.lib.getInput {
    name = "nixpkgs-esp-dev";
    flake = false;
  };

  # flake-compat reads ${esp-dev.outPath}/flake.nix and locks the inputs by the
  # hashes in its own flake.lock, i.e. it does *not* share this flake's inputs
  # the way `config.lib.mkFlake` does. That is exactly what is needed here,
  # because nixpkgs-esp-dev is written against nixos-25.11 and breaks on our
  # nixpkgs (nixpkgs-unstable, python 3.14 by default) in two places:
  #
  #  * Its flake.nix builds its own pkgs instance with a `config` spelled out in
  #    full, including
  #
  #      config.permittedInsecurePackages = [ "python3.13-ecdsa-0.19.1" ];
  #
  #    so nothing from this flake reaches it. Against our nixpkgs esptool's
  #    `ecdsa` is `python3.14-ecdsa-0.19.2`, which is not on that list, and
  #    evaluation aborts with "Refusing to evaluate package ... marked as
  #    insecure" — even though this flake's own config permits it.
  #  * Its prebuilt xtensa/riscv gdb links against `libpython3.10.so.1.0`
  #    (pkgs/esp-idf/tools.nix takes a `python310` and puts it in the tools'
  #    RPATH), and python310 no longer exists in nixpkgs-unstable, so those
  #    tools cannot even be patched.
  #
  # The cost is a second nixpkgs in the closure, but only the ESP tools come
  # from it; the rest of the shell stays on this flake's nixpkgs.
  flake-compat = config.lib.getInput {
    name = "flake-compat";
    flake = false;
  };

  esp-dev-outputs =
    (import "${flake-compat.outPath}/default.nix" {
      src = esp-dev.outPath;
      inherit (pkgs.stdenv.hostPlatform) system;
    }).outputs;

  mk-qoi-conv =
    pythonPackage:
    pythonPackage.buildPythonPackage rec {
      pname = "qoi-conv";
      version = "1.0.2";

      src = pkgs.fetchPypi {
        inherit pname version;
        sha256 = "sha256-Fc97/jZOlHJOSkw8kD+i1pEMYAqNAAS08HZKdrRMKcE=";
      };
      pyproject = true;
      build-system = [ pythonPackage.setuptools ];
      dependencies = with pythonPackage; [
        numpy
        pillow
      ];
    };

  # `esp-idf-full` carries both toolchain architectures (xtensa: esp32, esp32s2,
  # esp32s3; riscv: esp32c2/c3/c5/c6/c61/h2/h21/p4), the ULP assembler, openocd,
  # the Python environment with esptool, and esp-clang. That is the only
  # variant ESP-IDF 6.0 onwards ships, so there is no reason to offer the
  # trimmed-down `esp-idf-xtensa`/`esp-idf-riscv` split here.
  idf = esp-dev-outputs.packages.${pkgs.stdenv.hostPlatform.system}.esp-idf-full.override {
    extraPythonPackages =
      p: with p; [
        patch
        pillow
        (mk-qoi-conv p)
      ];
  };

  # Espressif's clang fork: the only LLVM that knows the xtensa/riscv targets.
  # A nixpkgs `clangd` would not understand the ESP-IDF compile flags.
  esp-clang = idf.tools.esp-clang;

  # The gcc drivers clangd is allowed to query. ESP-IDF ships newlib and
  # libstdc++ inside the toolchains, so their include paths cannot be guessed --
  # they have to be asked for. The two toolchain directories are stable for
  # `esp-idf-full`; only the compilers' basenames differ per chip
  # (xtensa-esp32-elf-gcc, xtensa-esp32s3-elf-gcc, riscv32-esp-elf-gcc, ...).
  xtensaToolchain = idf.tools.xtensa-esp-elf;
  riscvToolchain = idf.tools.riscv32-esp-elf;

  # ESP-IDF's own answer to code intelligence is clangd plus the
  # `compile_commands.json` that CMake writes into the build directory
  # (`project.cmake` sets CMAKE_EXPORT_COMPILE_COMMANDS ON, so `idf.py build`
  # and `idf.py reconfigure` both produce it). clangd finds that file on its own
  # (it also looks into a `build` subdirectory), but it does not ask the gcc
  # driver named in the compile command for the system includes unless the
  # driver matches `--query-driver`. Without that, every `#include <stdint.h>`
  # that should come from newlib is "file not found" -- which is exactly what
  # this wrapper fixes.
  #
  # Editors should see a plain `clangd`: the wrapper is installed under that
  # name (shadowing any other clangd in the shell), so it works without any
  # editor configuration. Arguments given by the editor are forwarded; a
  # `--query-driver` of its own is kept and ours is added on top.
  clangd = pkgs.writeShellScriptBin "clangd" ''
    exec ${esp-clang}/bin/clangd \
      --query-driver='${xtensaToolchain}/bin/*-gcc,${xtensaToolchain}/bin/*-g++,${riscvToolchain}/bin/*-gcc,${riscvToolchain}/bin/*-g++' \
      "$@"
  '';
in
{
  options.espidf = {
    enable = lib.mkEnableOption "tools for ESP-IDF (Espressif IoT Development Framework) development";

    lsp.enable =
      lib.mkEnableOption "`clangd` (Espressif's clang fork, wired to this shell's ESP-IDF toolchains)"
      // {
        default = true;
      };
  };

  config = lib.mkIf cfg.enable {
    # Order matters: `mkShell` appends each package's `bin` to $PATH in list
    # order, so the *first* package wins a name collision. `idf` puts
    # esp-clang's own `bin` on $PATH, and that directory contains a bare
    # `clangd` (no `--query-driver`). Listed after `idf`, our wrapper would be
    # shadowed by it: the editor then starts the bare binary, clangd cannot ask
    # `xtensa-esp32-elf-gcc` for the newlib include paths, and every
    # `#include <string.h>` in an ESP-IDF project is "file not found". Hence
    # the wrapper goes first.
    packages = lib.optional cfg.lsp.enable clangd ++ [
      idf
      pkgs.picocom
      pkgs.esptool
    ];
  };
}
