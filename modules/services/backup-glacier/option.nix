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

              s3Uri = mkOption {
                type = types.str;
                default = "";
                example = "s3://amzn-s4-mybucket-bucket/homeserver-backups/";
                description = ''
                  Where the streams go. The host is the bucket. The path is
                  the folder inside it, for example
                  s3://amzn-s4-mybucket-bucket/homeserver-backups/.
                  A trailing slash is optional. This is the address, not a
                  login; the AWS key file below is how the machine authenticates.
                  The service does not create the bucket.
                  Block all public access. Leave versioning off (old versions
                  are not restorable sends, and you pay for them forever).
                  Do not add a lifecycle rule that transitions or expires these
                  objects; this service deletes only what it uploaded, and only
                  after retentionDays. Changing the path does not move objects
                  that are already uploaded.
                '';
                rank = 30;
                ui = lib.neo.ui.mkUi {
                  label = "S3 URI";
                  summary = true;
                };
              };

              region = mkOption {
                type = types.str;
                default = "eu-central-2";
                example = "eu-central-2";
                description = ''
                  AWS region of that bucket. Default is eu-central-2.
                  The S3 URI does not include it. A mismatch writes to the
                  wrong place or the upload is rejected.
                '';
                rank = 40;
                ui = lib.neo.ui.mkUi {
                  label = "Region";
                  summary = true;
                };
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
                  Path to the AWS login, not the keys themselves.
                  Create an IAM user that can only touch this bucket, then an
                  access key for it. Put these two lines in a file on the OS disk:

                    AWS_ACCESS_KEY_ID=AKIA...
                    AWS_SECRET_ACCESS_KEY=...

                  No quotes and no export. Owner root, mode 0600.
                  This page stores the path. Do not paste the keys here:
                  settings end up in the Nix store, which every user on the
                  machine can read. systemd loads the file when the backup starts.
                  The IAM user needs s3:ListBucket and s3:GetBucketLocation on
                  the bucket, and s3:GetObject, s3:PutObject, s3:DeleteObject,
                  s3:AbortMultipartUpload, and s3:ListMultipartUploadParts
                  on the prefix. It does not need s3:CreateBucket.
                '';
                rank = 70;
                ui = lib.neo.ui.mkUi {label = "AWS key file";};
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
                The destination is one S3 URI (s3://bucket/prefix/), not a
                separate bucket and prefix.
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
