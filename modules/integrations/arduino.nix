{
  pkgs,
  config,
  lib,
  ...
}:

let
  cfg = config.arduino;

  # `arduino-nix` is the wrapper library, `arduino-index` a checkout of
  # bouk/arduino-indexes (plain source tree, hence `outPath` below).
  arduino-nix = config.lib.getInput "arduino-nix";
  arduino-index = config.lib.getInput "arduino-index";

  indexFile = name: "${toString arduino-index}/index/${name}";

  # `lib.attrByPath`, but the error says what was being looked up and suggests
  # what was probably meant. Package and library indexes have thousands of
  # entries, so they are only listed when that is actually readable.
  lookup =
    {
      what,
      root,
      path,
      # How to refer to the entry in the error, for entries named by a spec
      # rather than by an attribute path (`Name@version`, `packager:arch:version`).
      label ? lib.concatStringsSep "." path,
    }:
    lib.attrByPath path (
      let
        needle = lib.last path;
        parent = lib.attrByPath (lib.init path) { } root;
        names = if lib.isAttrs parent then lib.attrNames parent else [ ];
        similar = lib.take 10 (
          lib.filter (name: lib.hasInfix (lib.toLower needle) (lib.toLower name)) names
        );
      in
      throw ''
        arduino.${what}: '${label}' does not exist.
        ${
          if lib.length names <= 20 then
            "Available: ${lib.concatStringsSep ", " names}"
          else if similar != [ ] then
            "Did you mean: ${lib.concatStringsSep ", " similar}${
              lib.optionalString (lib.length similar == 10) ", ..."
            }?"
          else
            # A wrong version: the list is too long to print in full, but a
            # sample is still more useful than "not found".
            "No entry contains '${needle}'. The first ones are: ${lib.concatStringsSep ", " (lib.take 20 names)}, ..."
        }''
    ) root;

  # `libraries` entries are either "Name" (newest version in the index) or
  # "Name@1.2.3" (that version), matching how the arduino-cli names them.
  resolveLibrary =
    spec:
    let
      label = spec;
      parts = lib.splitString "@" spec;
      name = lib.head parts;
      versions = lookup {
        what = "libraries";
        root = pkgs.arduinoLibraries;
        path = [ name ];
        inherit label;
      };
    in
    if lib.length parts > 2 then
      throw "arduino.libraries: '${spec}' should be \"Name\" or \"Name@version\""
    else if lib.length parts == 1 then
      arduino-nix.latestVersion versions
    else
      lookup {
        what = "libraries";
        root = pkgs.arduinoLibraries;
        path = [
          name
          (lib.elemAt parts 1)
        ];
        inherit label;
      };

  # `cores` entries use the arduino-cli's own notation:
  # "packager:architecture" (newest version the indexes know) or
  # "packager:architecture:version". That maps onto
  # `pkgs.arduinoPackages.platforms.<packager>.<architecture>`.
  resolveCore =
    spec:
    let
      label = spec;
      parts = lib.splitString ":" spec;
      core = lookup {
        what = "cores";
        root = pkgs.arduinoPackages;
        path = [ "platforms" ] ++ lib.take 2 parts;
        inherit label;
      };
    in
    if lib.length parts == 2 || (lib.length parts == 3 && lib.last parts == "latest") then
      arduino-nix.latestVersion core
    else if lib.length parts == 3 then
      lookup {
        what = "cores";
        root = pkgs.arduinoPackages;
        path = [ "platforms" ] ++ parts;
        inherit label;
      }
    else
      throw "arduino.cores: '${spec}' should be \"packager:architecture\" or \"packager:architecture:version\", e.g. \"esp32:esp32\"";

  # esptool belongs to ESP32 work: flashing by hand (`esptool write-flash`,
  # `chip-id`, `erase-flash`) is routine there. Note that this is the nixpkgs
  # build; arduino-cli itself uses the esptool copy that ships inside the core's
  # data directory.
  wantsEsp32 = lib.any (spec: lib.hasPrefix "esp32:" spec) cfg.cores;

  # Built once: the language server needs the CLI's path as well as the package.
  arduinoCli = pkgs.wrapArduinoCLI {
    libraries = map resolveLibrary cfg.libraries ++ cfg.extraLibraries;
    # Cores pull in the tools they depend on themselves; anything in
    # `arduino.tools` is added on top.
    packages = map resolveCore cfg.cores ++ cfg.tools;
  };

  # `arduino-language-server` runs two builds per session and hands clangd a
  # compilation database from the *incremental* one only: `<tmp>/build`, made
  # with `--only-compilation-database --skip-libraries-discovery`. That database
  # has commands for the sketch and the core, but none for the libraries, so a
  # file inside a library directory has no command of its own -- e.g.
  # `libraries/Wire/src/Wire.h` or `Adafruit_SSD1306.h`. clangd then borrows the
  # nearest command it can find (in practice a core translation unit, whose
  # flags carry no library include paths), and every `#include <Wire.h>` inside
  # such a header becomes "file not found". That breaks go-to-definition,
  # completion and diagnostics while editing library code.
  #
  # The *full* build (`<tmp>/fullbuild`, done on every rebuild as well) does
  # contain the library commands. This wrapper therefore merges both databases
  # and points clangd at the merged one. The incremental database wins on
  # conflicts because it is the only one that knows
  # `<tmp>/build/sketch/<sketch>.ino.cpp`, the file clangd actually receives the
  # `didOpen`/`didChange` notifications for. Libraries added after clangd
  # started only show up after restarting the language server.
  arduinoClangd = pkgs.writeShellScriptBin "arduino-clangd" ''
    cdb=""
    for arg in "$@"; do
      case "$arg" in
        --compile-commands-dir=*) cdb="''${arg#--compile-commands-dir=}" ;;
      esac
    done

    # The drivers to whitelist are exactly the compilers the build used, and we
    # know them once the database is merged: take the program of every command.
    # Exact paths beat a glob -- nothing else under /nix/store gets trusted.
    query_driver="--query-driver=/nix/store/*/packages/**"
    args=()
    if [ -f "$cdb/compile_commands.json" ]; then
      tmp="$(dirname "$cdb")"
      full="$tmp/fullbuild/compile_commands.json"
      merged="$tmp/merged"
      if [ -f "$full" ] && mkdir -p "$merged" &&
        ${lib.getExe pkgs.jq} -s '.[0] + .[1] | unique_by(.file)' \
          "$cdb/compile_commands.json" "$full" > "$merged/compile_commands.json.tmp" &&
        mv "$merged/compile_commands.json.tmp" "$merged/compile_commands.json"; then
        cdb="$merged"
        drivers="$(${lib.getExe pkgs.jq} -r '
          [ .[] | (.arguments // (.command | split(" "))) | .[0] ]
          | map(select(. != null and . != "")) | unique | join(",")' \
          "$cdb/compile_commands.json")"
        if [ -n "$drivers" ]; then query_driver="--query-driver=$drivers"; fi
      fi
    fi

    seen_query_driver=""
    for arg in "$@"; do
      case "$arg" in
        --compile-commands-dir=*) args+=("--compile-commands-dir=$cdb") ;;
        # ALS spells it with a single dash, nixpkgs' clangd wrapper only
        # recognises the double-dash form and otherwise injects the host
        # glibc/libstdc++ headers (see the comment above).
        -query-driver=* | --query-driver=*)
          args+=("$query_driver")
          seen_query_driver=1
          ;;
        *) args+=("$arg") ;;
      esac
    done

    [ -n "$seen_query_driver" ] || args+=("$query_driver")

    exec ${pkgs.clang-tools}/bin/clangd "''${args[@]}"
  '';

  # arduino-language-server ships as a bare Go binary: it has to be told where
  # clangd and arduino-cli live, and it refuses to start without `-cli-config`.
  # Bake the three paths in so an editor can launch it without arguments; the
  # config points at the same read-only directories the wrapped CLI uses.
  # `pkgs.clang-tools` has no `meta.mainProgram` (and ships dozens of binaries),
  # so the clangd path is spelled out.
  clangd = "${arduinoClangd}/bin/arduino-clangd";

  arduinoCliConfig = pkgs.writeText "arduino-cli.yaml" ''
    directories:
      data: ${arduinoCli.dataPath}
      user: ${arduinoCli.userPath}
  '';

  arduinoLanguageServer = pkgs.writeShellScriptBin "arduino-language-server" ''
    exec ${lib.getExe pkgs.arduino-language-server} \
      -cli ${lib.getExe arduinoCli} \
      -clangd ${clangd} \
      -cli-config ${arduinoCliConfig} \
      "$@"
  '';

in
{
  options.arduino = {
    enable = lib.mkEnableOption "tools for Arduino Development";

    packageIndexes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "package_index.json" ];
      description = ''
        Package index files to load from the `arduino-index` input (relative to
        its `index/` directory). Every file added here makes the cores and tools
        it lists available to `arduino.cores` and `arduino.tools`.

        The main `package_index.json` provides the builtin tools arduino-cli
        needs, so it normally stays in the list.
      '';
      example = lib.literalExpression ''
        [
          "package_index.json"
          "package_rp2040_index.json"
        ]
      '';
    };

    libraryIndexes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "library_index.json" ];
      description = ''
        Library index files to load from the `arduino-index` input (relative to
        its `index/` directory). Libraries listed by these files can be used in
        `arduino.libraries`.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "esp32:esp32:latest" ];
      description = ''
        Cores (platforms) to pre-install into the arduino-cli data directory,
        written as `packager:architecture` or `packager:architecture:version`.
        The newest ESP32 core is installed by default.

        Leaving the version out (or spelling it `latest`) installs the newest
        version the indexes know about. Those indexes are pinned by
        `nix/sources.json`, so "latest" only moves when that pin is updated.
        The packager has to be provided by one of `arduino.packageIndexes`.

        A wrong version is reported with the versions the index actually has.
        Set this to `[ ]` to install no core at all.
      '';
      example = [
        "esp32:esp32:3.3.12"
        "arduino:avr:1.8.8"
      ];
    };

    lsp.enable =
      lib.mkEnableOption "the Arduino language server (`arduino-language-server` with `clangd`, wired to this shell's arduino-cli)"
      // {
        default = true;
      };

    libraries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Libraries to pre-install into the arduino-cli user directory, written as
        `Name` (newest version in the library index) or `Name@version` (pinned).
        The name has to match the library index exactly, including spaces.
      '';
      example = [
        "Ethernet"
        "Adafruit SSD1306@2.5.13"
      ];
    };

    tools = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Extra tool derivations to install into the arduino-cli data directory,
        on top of the tools the selected cores pull in themselves (cores depend
        on their toolchain, so it is normally installed automatically). Useful
        for tools that no core lists, e.g.
      '';
      example = lib.literalExpression ''
        [ pkgs.arduinoPackages.tools.esp32.esptool."3.0.0" ]
      '';
    };

    extraLibraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Library derivations to install into the arduino-cli user directory,
        bypassing the library index. Useful for libraries that are not published
        there, or for a checkout of a library that is being worked on.
      '';
      example = lib.literalExpression ''
        [ (pkgs.fetchFromGitHub {
            owner = "arduino-libraries";
            repo = "ArduinoJson";
            rev = "v7.0.0";
            hash = "sha256-...";
          }) ]
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The package/library overlays turn the indexes into `pkgs.arduinoPackages`
    # and `pkgs.arduinoLibraries`; they have to be installed before
    # `wrapArduinoCLI` is used, which is why this is not just `packages`.
    overlays = [
      arduino-nix.overlay
    ]
    ++ map (name: arduino-nix.mkArduinoPackageOverlay (indexFile name)) cfg.packageIndexes
    ++ map (name: arduino-nix.mkArduinoLibraryOverlay (indexFile name)) cfg.libraryIndexes;

    packages = [
      arduinoCli
      pkgs.picocom
    ]
    ++ lib.optional cfg.lsp.enable arduinoLanguageServer
    ++ lib.optional wantsEsp32 pkgs.esptool;
  };
}
