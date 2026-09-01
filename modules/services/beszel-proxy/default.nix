# Implementation: rewrite SWAG site-conf for external Beszel after Neo generates proxyPass vhost.
{...}: {
  flake.modules.nixos.beszel-proxy = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.beszel-proxy;
      appdataSwag = "${config.neo.core.volumes.appdata}/swag";
      siteConf = "${appdataSwag}/nginx/site-confs/${cfg.domain}.conf";
      # PocketBase/Beszel rejects the stock SWAG proxy.conf header set with HTTP 400.
      # Keep Host as the public name; forward proto/IP; enable websockets; no full proxy.conf.
      confContent = ''
        server {
          listen 80;
          listen [::]:80;
          server_name ${cfg.domain};
          return 301 https://$server_name$request_uri;
        }

        server {
          include /config/nginx/listen-https.conf;
          http2 on;
          server_name ${cfg.domain};

          include /config/nginx/ssl.conf;
          client_max_body_size 0;
          include /config/nginx/geo-access.conf;

          location / {
            include /config/nginx/resolver.conf;
            set $beszel_upstream ${cfg.upstreamHost}:${toString cfg.upstreamPort};
            proxy_pass http://$beszel_upstream;

            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;

            proxy_read_timeout 86400;
            proxy_buffering off;
          }
        }
      '';
      writeSiteConf = lib.neo.mkActivationScriptForFile config {
        filePath = siteConf;
        content = confContent;
        mode = "0644";
      };
      restoreScript = pkgs.writeShellScript "swag-beszel-proxy-fix" ''
        set -euo pipefail
        ${writeSiteConf}
        # Reload nginx if the container is already up (patcher / restart path).
        if command -v docker >/dev/null 2>&1 && docker exec swag test -f /config/nginx/nginx.conf 2>/dev/null; then
          if docker exec swag nginx -t 2>/dev/null; then
            docker exec swag nginx -s reload 2>/dev/null || true
          fi
        fi
      '';
    in {
      config = mkIf cfg.enabled {
        # After Neo's docker-swag preStart has wiped/regenerated site-confs (stock proxyPass).
        systemd.services.docker-swag.preStart = mkAfter writeSiteConf;

        # After swag-patcher / on boot: keep conf correct and reload.
        systemd.services.swag-beszel-proxy-fix = {
          description = "Ensure Beszel SWAG site conf stays PocketBase-safe";
          after = ["docker-swag.service" "swag-patcher.service"];
          wants = ["docker-swag.service"];
          partOf = ["docker-swag.service"];
          wantedBy = ["multi-user.target" "docker-swag.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${restoreScript}";
          };
        };
      };
    };
}
