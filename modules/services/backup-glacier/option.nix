# Options: scheduled sync of a local directory to AWS S3 Glacier via rclone.
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
{...}: {
  flake.modules.nixos.backup-glacier-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.backup-glacier = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Scheduled backup of a local directory to AWS S3 Glacier" {
                rank = 0;
              };
              sourcePath = mkOption {
                type = types.str;
                default = "/mnt/backups";
                description = "Local directory to back up, e.g. neo.services.storage-disks.mountPoint.";
              };
              bucket = mkOption {
                type = types.str;
                default = "";
                example = "my-backups-bucket";
                description = "Destination S3 bucket name. Must already exist.";
              };
              bucketPath = mkOption {
                type = types.str;
                default = "";
                description = "Optional prefix inside the bucket to sync into.";
              };
              region = mkOption {
                type = types.str;
                default = "us-east-1";
                description = "AWS region of the destination bucket.";
              };
              storageClass = mkOption {
                type = types.enum ["GLACIER" "DEEP_ARCHIVE"];
                default = "DEEP_ARCHIVE";
                description = "S3 storage class objects are uploaded as.";
              };
              environmentFile = mkOption {
                type = types.str;
                default = "";
                example = "/run/secrets/backup-glacier-aws.env";
                description = ''
                  Path to an EnvironmentFile (outside the nix store) providing
                  AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. Never put credentials
                  directly in a NixOS option - the nix store is world readable.
                '';
              };
              schedule = mkOption {
                type = types.str;
                default = "*-*-* 03:00:00";
                description = "systemd calendar expression for how often the backup runs.";
              };
              extraRcloneFlags = mkOption {
                type = types.listOf types.str;
                default = [];
                example = ["--transfers=4" "--checkers=8"];
                description = "Extra flags appended to the rclone sync command.";
              };
            }
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/rclone.svg";
              description = ''
                Periodically syncs a local directory (e.g. the storage-disks backup
                dataset) to an AWS S3 bucket using rclone, uploading objects
                directly into the Glacier or Glacier Deep Archive storage class
                for long-term, low-cost offsite retention.
              '';
              projectUrl = "https://rclone.org";
              githubUrl = "https://github.com/rclone/rclone";
            };
        };
        default = {};
        description = "Scheduled offsite backup to AWS S3 Glacier";
      };
    };
}
