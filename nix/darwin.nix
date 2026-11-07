# programs.swish for nix-darwin: the shell for every user, and listed in
# /etc/shells so that it can be a login shell (`chsh -s`).
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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    environment.shells = [ cfg.package ];
  };
}
