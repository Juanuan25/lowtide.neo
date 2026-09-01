# Options: external Beszel hub reverse-proxy (PocketBase-safe).
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
{...}: {
  flake.modules.nixos.beszel-proxy-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.beszel-proxy = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Beszel external hub proxy (PocketBase-safe SWAG vhost)" {
                rank = 0;
              };
              domain = mkOption {
                type = types.str;
                default = "";
                example = "beszel.example.com";
                description = "Public hostname (must match services.swag.proxyPass key or be listed there).";
              };
              upstreamHost = mkOption {
                type = types.str;
                default = "";
                example = "192.168.0.10";
                description = "LAN IP/hostname of the machine running the Beszel hub.";
              };
              upstreamPort = mkOption {
                type = types.port;
                default = 8090;
                description = "Beszel hub HTTP port.";
              };
            }
            // lib.neo.mkServiceMeta {
              category = "Network";
              icon = "https://raw.githubusercontent.com/henrygd/beszel/main/beszel/site/static/icon.svg";
              description = ''
                Fixes Neo SWAG proxyPass for an external Beszel hub (PocketBase).
                Stock proxyPass includes full proxy.conf and returns HTTP 400 to Beszel.
                This module overwrites the generated site conf after SWAG preStart with a
                minimal reverse-proxy (Host + X-Forwarded-* + WebSocket) that works.
              '';
              projectUrl = "https://github.com/henrygd/beszel";
              githubUrl = "https://github.com/henrygd/beszel";
            };
        };
        default = {};
        description = "External Beszel hub behind SWAG";
      };
    };
}
