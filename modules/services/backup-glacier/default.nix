# Implementation: systemd timer runs rclone sync into an AWS S3 Glacier storage class.
{...}: {
  flake.modules.nixos.backup-glacier = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.backup-glacier;
      destPath =
        if cfg.bucketPath != ""
        then "${cfg.bucket}/${cfg.bucketPath}"
        else cfg.bucket;
      # Inline remote: no rclone config file needed, credentials come from EnvironmentFile.
      rcloneRemote = ":s3,provider=AWS,region=${cfg.region},storage_class=${cfg.storageClass},env_auth=true:${destPath}";
      syncScript = pkgs.writeShellScript "backup-glacier-sync" ''
        set -euo pipefail
        exec ${pkgs.rclone}/bin/rclone sync \
          "${cfg.sourcePath}" \
          "${rcloneRemote}" \
          ${escapeShellArgs cfg.extraRcloneFlags}
      '';
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = cfg.bucket != "";
            message = "neo.services.backup-glacier: bucket must be set to an existing S3 bucket name.";
          }
          {
            assertion = cfg.environmentFile != "";
            message = ''
              neo.services.backup-glacier: environmentFile must point to a file
              (outside the nix store) providing AWS_ACCESS_KEY_ID and
              AWS_SECRET_ACCESS_KEY.
            '';
          }
        ];

        systemd.services.backup-glacier = {
          description = "Sync ${cfg.sourcePath} to AWS S3 Glacier (${cfg.bucket})";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${syncScript}";
            EnvironmentFile = cfg.environmentFile;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = "read-only";
          };
        };

        systemd.timers.backup-glacier = {
          description = "Timer for backup-glacier sync";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.schedule;
            Persistent = true;
          };
        };
      };
    };
}
