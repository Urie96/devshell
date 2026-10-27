{
  pkgs,
  config,
  ...
}:
{
  options.arduino = { };

  config =
    let
      arduino-nix = config.lib.getInput "arduino-nix";
      arduino-index = config.lib.getInput "arduino-index";
    in
    {
      overlays = [
        (arduino-nix.overlay)
        (arduino-nix.mkArduinoPackageOverlay (arduino-index + "/index/package_index.json"))
        # (arduino-nix.mkArduinoPackageOverlay (arduino-index + "/index/package_rp2040_index.json"))
        (arduino-nix.mkArduinoLibraryOverlay (arduino-index + "/index/library_index.json"))
      ];

      packages =
        let
          arduino-cli = pkgs.wrapArduinoCLI {
            libraries = [
              (arduino-nix.latestVersion pkgs.arduinoLibraries."Adafruit SSD1306")
              (arduino-nix.latestVersion pkgs.arduinoLibraries."Adafruit GFX Library")
              (arduino-nix.latestVersion pkgs.arduinoLibraries."Adafruit BusIO")
            ];

            packages = with pkgs.arduinoPackages; [
              platforms.esp32.esp32."3.3.2"
            ];
          };
        in
        [ arduino-cli ];
    };
}
