# Hermes skill for backup-glacier.
{...}: {
  flake.modules.nixos.backup-glacier-skills = {
    config,
    lib,
    ...
  }: let
    cfg = config.neo.services.backup-glacier;
    domain = config.neo.services.swag.domain or null;
  in {
    config.neo.services.backup-glacier.skill.conf = lib.neo.mkServiceSkill {
      service = "backup-glacier";
      inherit cfg domain;
      description = "Offsite ZFS snapshot streams to S3 Glacier";
      tags = ["neo" "backup" "zfs"];
      body = ''
        ## When to Use
        Offsite copy of the Sanoid replicas, a failed upload, or a restore after the backup disks are lost.

        ## Architecture
        - Local hot copy: storage-disks pool (default datadisk) plus Sanoid/syncoid into datadisk/backups/<pool>.
        - This service sends the latest snapshot of those datasets (`zfs send -w` when the dataset is encrypted) and uploads one new object with rclone.
        - It does not rclone-sync the mount. Do not add a bucket lifecycle rule that moves or expires objects.
        - Deep Archive (default) takes up to 12 hours to thaw. Flexible Retrieval is faster and costs more. Do not switch the class of objects already uploaded; new objects use the current class, old ones stay where they are.
        - State of what was uploaded: the service appdata (`state.json`). Clearing appdata causes a new full send. It does not delete old objects early.

        ## Credentials
        - Address: `s3Uri`, for example `s3://bucket/homeserver-backups/`. That names the bucket and the folder. It is not a password.
        - Login: `accessKeyId` and `secretAccessKey` on this service's page. Create them in AWS IAM, paste both, Activate. There is no key file. Do not repeat the secret in chat.
        - Region defaults to `eu-central-2`. It must be the bucket's region. The URI does not include it.
        - ZFS key: storage-disks keyFile (default `/root/keys/datadisk.key`). It is not in the bucket. Without a copy of it, a raw stream cannot be mounted.

        ## Procedures
        1. Confirm the backup pool is imported and the dataset has snapshots: `zfs list -t snapshot <dataset>`.
        2. Run one upload: `systemctl start backup-glacier.service` and read `journalctl -u backup-glacier -b --no-pager`.
        3. A restore is manual and must not receive onto the live pool. Thaw the full object and the incrementals after it (S3 console or `rclone backend restore`), download them in order, then `zfs recv` into a new dataset. Load the datadisk key to mount a raw stream.

        ## Pitfalls
        - Plaintext datasets are refused unless allowUnencryptedSend is set. Do not turn that on to "make it work".
        - retentionDays shorter than 180 (Deep Archive) or 90 (Flexible Retrieval) is rejected. Deleting younger objects still costs the rest of the minimum duration.
        - A full stream is about the size of the dataset. fullEveryDays (default 30) and retentionDays (default 180) keep roughly six full copies. Raise fullEveryDays before the first run if the pool is large.
        - IAM needs s3:ListBucket and s3:GetBucketLocation on the bucket, and s3:GetObject, s3:PutObject, s3:DeleteObject, s3:AbortMultipartUpload, and s3:ListMultipartUploadParts on the prefix. It does not need s3:CreateBucket or s3:*.
        - The only safe bucket lifecycle rule is aborting incomplete multipart uploads after a few days. Do not expire or transition objects.
        - One stream cannot exceed 5 TiB (S3's object limit). A bigger dataset has to be split.
        - A corrupt state.json stops the run. Moving it aside starts a new full stream and does not delete remote objects.
        - Do not restore over zroot or over datadisk/backups.

        ## Verification
        - `systemctl is-active backup-glacier.timer` is active.
        - The latest journal line for a quiet day says the snapshot is already uploaded.
        - `zfs list -t snapshot` on the replica still shows the snapshot named in that line.
      '';
    };
  };
}
