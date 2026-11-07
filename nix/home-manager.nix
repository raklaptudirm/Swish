# programs.swish for home-manager: the shell in the user's packages, and its
# config file, `~/.config/swish/config.swish`, which Swish runs as it starts.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.swish;
in
{
  options.programs.swish = {
    enable = lib.mkEnableOption "Swish, a shell whose language is Swift";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.swish;
      defaultText = lib.literalExpression "swish.packages.\${system}.swish";
      description = "The Swish package to install.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        func gs() { git status --short }
      '';
      description = ''
        Swift source for `$XDG_CONFIG_HOME/swish/config.swish`, run as the shell
        starts. Nothing is written when it is empty, so a file kept by hand stays.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    xdg.configFile."swish/config.swish" = lib.mkIf (cfg.config != "") { text = cfg.config; };
  };
}
