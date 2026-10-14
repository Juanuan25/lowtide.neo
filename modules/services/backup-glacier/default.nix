# Implementation: zfs send | rclone rcat into Glacier. Not rclone sync.
{...}: {
  flake.modules.nixos.backup-glacier = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.backup-glacier;
      disks = config.neo.services.storage-disks or {};
      classMinimum =
        if cfg.storageClass == "DEEP_ARCHIVE"
        then 180
        else 90;
      datasetsFile = pkgs.writeText "backup-glacier-datasets" (
        concatStringsSep "\n" cfg.datasets + "\n"
      );
      script = pkgs.writeShellScript "backup-glacier-run" (builtins.readFile ./run.sh);
      # s3://bucket/prefix/path/ -> bucket name and key prefix. Assertions reject
      # anything that is not that shape before these are used.
      s3Segments = filter (s: s != "") (splitString "/" (removePrefix "s3://" cfg.s3Uri));
      bucket =
        if s3Segments == []
        then ""
        else head s3Segments;
      prefix = concatStringsSep "/" (
        if s3Segments == []
        then []
        else tail s3Segments
      );
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = cfg.datasets != [];
            message = "neo.services.backup-glacier: datasets must list at least one ZFS dataset.";
          }
          {
            assertion =
              builtins.match "s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9](/[A-Za-z0-9._-]+)+/?" cfg.s3Uri
              != null
              && all (s: s != "." && s != "..") s3Segments;
            message = "neo.services.backup-glacier: s3Uri must look like s3://bucket/prefix/ (a bucket name, then at least one path segment).";
          }
          {
            assertion = builtins.match "[a-z][a-z0-9-]+" cfg.region != null;
            message = "neo.services.backup-glacier: region must be an AWS region (default eu-central-2).";
          }
          {
            assertion =
              cfg.accessKeyId
              != ""
              && builtins.match "[A-Za-z0-9]{16,128}" cfg.accessKeyId != null;
            message = "neo.services.backup-glacier: accessKeyId must be the IAM access key ID from AWS.";
          }
          {
            assertion =
              cfg.secretAccessKey
              != ""
              && builtins.match "[^[:space:]\"']+" cfg.secretAccessKey != null;
            message = "neo.services.backup-glacier: secretAccessKey must be the secret AWS showed once, one line, no quotes.";
          }
          {
            assertion = cfg.retentionDays >= classMinimum;
            message = "neo.services.backup-glacier: retentionDays must be at least ${toString classMinimum} for ${cfg.storageClass}, or deleted objects are billed for the rest of the minimum storage duration.";
          }
          {
            assertion = cfg.bwLimit == null || cfg.bwLimit == "" || builtins.match "[0-9]+[KMGkmg]?" cfg.bwLimit != null;
            message = "neo.services.backup-glacier: bwLimit must look like 8M, or be empty.";
          }
          {
            assertion = all (ds: builtins.match "/.*" ds == null && ds != "" && !(hasInfix "\n" ds)) cfg.datasets;
            message = "neo.services.backup-glacier: datasets are ZFS names (datadisk/backups/zroot), not mount paths.";
          }
        ];

        systemd.services.backup-glacier = {
          description = "ZFS send of backup datasets to S3 ${cfg.storageClass}";
          after =
            optional (disks.enabled or false) "storage-disks-ensure-imported.service"
            ++ ["network-online.target"];
          # Same reason as syncoid: import (and unlock) just before the send.
          # The import unit exits 0 when the disks are absent, so a missing
          # pool fails here, on the zfs list, instead of stalling boot.
          requires = optional (disks.enabled or false) "storage-disks-ensure-imported.service";
          path = [
            "/run/booted-system/sw/bin"
            pkgs.zfs
            pkgs.rclone
            pkgs.python3
            pkgs.coreutils
            pkgs.util-linux
            pkgs.gawk
          ];
          environment = {
            BACKUP_GLACIER_STATE = cfg.appdata;
            BACKUP_GLACIER_DATASETS_FILE = datasetsFile;
            BACKUP_GLACIER_BUCKET = bucket;
            BACKUP_GLACIER_REGION = cfg.region;
            BACKUP_GLACIER_PREFIX = prefix;
            BACKUP_GLACIER_STORAGE_CLASS = cfg.storageClass;
            BACKUP_GLACIER_PLANNER = "${./plan.py}";
            BACKUP_GLACIER_RETENTION_DAYS = toString cfg.retentionDays;
            BACKUP_GLACIER_FULL_EVERY_DAYS = toString cfg.fullEveryDays;
            BACKUP_GLACIER_ALLOW_PLAINTEXT =
              if cfg.allowUnencryptedSend
              then "1"
              else "0";
            BACKUP_GLACIER_RECURSIVE =
              if cfg.recursive
              then "1"
              else "0";
            BACKUP_GLACIER_BWLIMIT =
              if cfg.bwLimit == null || cfg.bwLimit == ""
              then ""
              else cfg.bwLimit;
            AWS_ACCESS_KEY_ID = cfg.accessKeyId;
            AWS_SECRET_ACCESS_KEY = cfg.secretAccessKey;
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = script;
            Nice = 19;
            IOSchedulingClass = "idle";
            IOSchedulingPriority = 7;
            TimeoutStartSec = "infinity";
            PrivateTmp = true;
          };
          stopIfChanged = false;
          restartIfChanged = false;
        };

        systemd.timers.backup-glacier = {
          description = "Daily ZFS send to S3 Glacier";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.schedule;
            Persistent = true;
            RandomizedDelaySec = "15min";
            AccuracySec = "1m";
            Unit = "backup-glacier.service";
          };
        };
      };
    };
}
