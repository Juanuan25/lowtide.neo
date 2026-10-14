# Options: offsite copy of Sanoid replicas as immutable ZFS send streams.
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
{...}: {
  flake.modules.nixos.backup-glacier-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; let
      sanoid = config.neo.services.sanoid or {};
      leaf = ds: last (splitString "/" ds);
      # Same dest path Sanoid/syncoid writes: <destPrefix>/<leaf>.
      defaultDatasets =
        if (sanoid.datasets or []) != []
        then map (ds: "${sanoid.destPrefix or "datadisk/backups"}/${leaf ds}") sanoid.datasets
        else ["datadisk/backups/zroot"];
      hostname = config.neo.core.hostname or "neo";
      defaultPrefix =
        if builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" hostname != null
        then hostname
        else "neo";
    in {
      options.neo.services.backup-glacier = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Offsite ZFS send of the Sanoid replicas to S3 Glacier" {
                rank = 0;
              };

              datasets = mkOption {
                type = types.listOf types.str;
                default = defaultDatasets;
                example = ["datadisk/backups/zroot"];
                description = ''
                  ZFS datasets to upload. Defaults to the datasets Sanoid replicates
                  onto the backup pool (<destPrefix>/<source leaf>, usually
                  datadisk/backups/zroot). This is the replica, not zroot itself
                  and not the mounted directory. A file sync of the mount would
                  upload plaintext and rewrite Glacier objects every day.
                '';
                rank = 10;
                ui = lib.neo.ui.mkUi {label = "Datasets";};
              };

              recursive = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Also upload child datasets. Sanoid replicates those with
                  --recursive, and a non-recursive send of the parent would
                  leave them behind.
                '';
                rank = 20;
                ui = lib.neo.ui.mkUi {label = "Include child datasets";};
              };

              bucket = mkOption {
                type = types.str;
                default = "";
                example = "lowtide-backups";
                description = ''
                  Existing S3 bucket. The service does not create it.
                  Block all public access. Leave versioning off (old versions
                  are not restorable sends, and you pay for them forever).
                  Do not add a lifecycle rule that transitions or expires these
                  objects; this service deletes only what it uploaded, and only
                  after retentionDays.
                '';
                rank = 30;
                ui = lib.neo.ui.mkUi {
                  label = "Bucket";
                  summary = true;
                };
              };

              region = mkOption {
                type = types.str;
                default = "";
                example = "eu-central-1";
                description = "AWS region of that bucket. No default: the wrong region writes to the wrong place.";
                rank = 40;
                ui = lib.neo.ui.mkUi {
                  label = "Region";
                  summary = true;
                };
              };

              prefix = mkOption {
                type = types.str;
                default = defaultPrefix;
                description = ''
                  Key prefix inside the bucket. Defaults to the hostname so two
                  machines do not share a key space. Changing it does not move
                  objects that are already uploaded.
                '';
                rank = 50;
                ui = lib.neo.ui.mkUi {label = "Prefix";};
              };

              storageClass = mkOption {
                type = types.enum ["DEEP_ARCHIVE" "GLACIER"];
                default = "DEEP_ARCHIVE";
                description = ''
                  Storage class for new objects. Deep Archive is the default
                  because these objects are written once and opened only if the
                  backup disks are gone. A restore takes up to 12 hours.
                  Glacier Flexible Retrieval is the faster cold class (minutes
                  to hours) and costs more. Instant Retrieval is not used:
                  nothing reads these objects on the daily run.
                  Minimum storage is 180 days for Deep Archive and 90 days for
                  Flexible Retrieval. retentionDays must be at least that long,
                  or AWS bills the remainder when an object is deleted.
                '';
                rank = 60;
                ui = lib.neo.ui.mkUi {
                  label = "Storage class";
                  summary = true;
                  choiceLabels = {
                    DEEP_ARCHIVE = "Deep Archive (12h restore)";
                    GLACIER = "Flexible Retrieval";
                  };
                };
              };

              environmentFile = mkOption {
                type = types.str;
                default = "";
                example = "/root/keys/backup-glacier-aws.env";
                description = ''
                  Absolute path of a root-only file (mode 0600) with
                  AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, one KEY=value
                  per line, no quotes and no export. Not a Nix store path:
                  the store is world-readable. The IAM user needs
                  s3:ListBucket and s3:GetBucketLocation on the bucket, and
                  s3:GetObject, s3:PutObject, s3:DeleteObject,
                  s3:AbortMultipartUpload, and s3:ListMultipartUploadParts
                  on the prefix. It does not need s3:CreateBucket.
                '';
                rank = 70;
                ui = lib.neo.ui.mkUi {label = "AWS credentials file";};
              };

              schedule = mkOption {
                type = types.str;
                default = "*-*-* 04:30:00";
                description = ''
                  systemd OnCalendar for the upload. Default is daily at 04:30,
                  after the 02:00 scrub. Each run uploads only the latest
                  snapshot, not every hourly snapshot Sanoid kept locally.
                '';
                rank = 80;
                ui = lib.neo.ui.mkUi {label = "Schedule";};
              };

              retentionDays = mkOption {
                type = types.ints.positive;
                default = 180;
                description = ''
                  Keep uploaded streams this many days, and never delete anything
                  younger than that. Default 180 matches Deep Archive's minimum
                  storage duration. The oldest full stream still needed to restore
                  the kept window is retained even if it is older than this.
                  Raising it keeps more full copies of the pool.
                '';
                rank = 82;
                ui = lib.neo.ui.mkUi {
                  label = "Keep streams (days)";
                  summary = true;
                };
              };

              fullEveryDays = mkOption {
                type = types.ints.positive;
                default = 30;
                description = ''
                  Send a full stream when the newest full is older than this and
                  there is a new snapshot. Otherwise send an incremental from the
                  last uploaded snapshot. Default 30 days: a restore is one full
                  plus at most a month of incrementals. With retentionDays at 180
                  that is about six full copies in Glacier. Raise this if the
                  pool is large and the upload hurts; lower it if you want a
                  shorter incremental chain.
                '';
                rank = 84;
                ui = lib.neo.ui.mkUi {label = "Full stream every (days)";};
              };

              bwLimit = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "8M";
                description = ''
                  Optional rclone bandwidth cap (for example 8M). Empty means
                  unlimited. The default schedule is the middle of the night so
                  a cap is usually unnecessary, and a cap that is too low makes
                  a full stream take days.
                '';
                rank = 86;
                ui = lib.neo.ui.mkUi {label = "Bandwidth cap";};
              };

              allowUnencryptedSend = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Allow zfs send of a dataset whose encryption property is off.
                  That stream is plaintext in AWS. Leave this off. The datadisk
                  replica is encrypted; zfs send -w uploads ciphertext and the
                  key file stays on the OS disk. A backup you cannot decrypt
                  later is useless, so keep a copy of that key somewhere that is
                  not only this machine and not in the bucket.
                '';
                rank = 88;
                ui = lib.neo.ui.mkUi {label = "Allow plaintext sends";};
              };
            }
            // lib.neo.mkSystemdUnits ["backup-glacier"]
            // lib.neo.mkSystemdTimers ["backup-glacier"]
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/backup-glacier"
            // lib.neo.mkServiceMeta {
              category = "Storage";
              iframeCompatible = false;
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                Offsite copy of the Sanoid replicas that already live on the
                backup disks. Once a day it sends the latest snapshot of each
                dataset (raw, so an encrypted datadisk stays encrypted) and
                uploads that stream as one new S3 object. It does not sync the
                mounted files. The local pool is the copy you restore from.
                Glacier is the copy for when those disks are gone, and a Deep
                Archive restore takes hours.

                The first run of a dataset is a full send. Later runs are
                incremental until fullEveryDays, then a new full. Objects are
                not overwritten. Clearing this service's appdata forgets which
                snapshots were uploaded and the next run sends a full stream
                again; it does not delete the old objects until they age out.
                A corrupt state file stops the run instead of sending the pool
                again. Move it aside only when a new full stream is acceptable.

                This is not the old rclone sync. sourcePath, bucketPath, and
                extraRcloneFlags are gone; a file sync rewrites Glacier objects.
              '';
              projectUrl = "https://rclone.org";
              githubUrl = "https://github.com/rclone/rclone";
            }
            // lib.neo.mkSkillOptions {};
        };
        default = {};
        description = "Offsite ZFS send of Sanoid replicas to S3 Glacier";
      };
    };
}
