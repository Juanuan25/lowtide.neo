# Options: import an attached ZFS pool, or format disks into a new one.
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
# This pool is the Sanoid destination (destPrefix = <poolName>/<dataset>).
{...}: {
  flake.modules.nixos.storage-disks-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.storage-disks = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "ZFS pool on attached disks, mounted as the backup destination" {
                rank = 0;
              };
              mode = mkOption {
                type = types.enum ["import" "format"];
                default = "import";
                description = ''
                  import: on boot, import poolName if its disks are attached.
                  Never wipes disks. A missing pool does not fail boot.
                  format: does not touch disks on activate. It only unlocks
                  `storage-disks-format --yes`, which creates the pool, the
                  dataset, and the mountpoints. Set this back to import after.
                '';
                rank = 10;
              };
              encryption = mkOption {
                type = types.enum ["keyfile" "none"];
                default = "keyfile";
                description = ''
                  keyfile: native ZFS encryption (aes-256-gcm). The raw 32-byte
                  key is keyFile on the OS disk, not in the Nix store. Boot
                  loads that file. It never asks for a passphrase, so a headless
                  boot cannot sit on a prompt. Without the key the disks are
                  unreadable — keep a copy somewhere else.
                  none: plaintext pool. Anyone with the disks can read them.
                  No key is loaded.
                  Format uses this choice. Import follows the pool itself:
                  an encrypted pool is unlocked with keyFile, a plaintext pool
                  is just mounted.
                '';
                rank = 15;
              };
              poolName = mkOption {
                type = types.str;
                default = "datadisk";
                description = "ZFS pool name. Must match `zpool import`.";
                rank = 20;
              };
              dataset = mkOption {
                type = types.str;
                default = "backups";
                description = ''
                  Dataset under the pool (<poolName>/<dataset>).
                  Sanoid destPrefix should be this same path
                  (default datadisk/backups).
                '';
                rank = 30;
              };
              poolMountPoint = mkOption {
                type = types.str;
                default = "/mnt/external_ssd";
                description = "Native ZFS mountpoint of the pool root. Not a NixOS fileSystems entry.";
                rank = 40;
              };
              mountPoint = mkOption {
                type = types.str;
                default = "/mnt/external_ssd/backups";
                description = "Native ZFS mountpoint of <poolName>/<dataset>. Not a NixOS fileSystems entry.";
                rank = 50;
              };
              devices = mkOption {
                type = types.listOf types.str;
                default = [
                  "/dev/disk/by-id/usb-Samsung_PSSD_T7_S5TNNK0N412932P-0:0"
                  "/dev/disk/by-id/ata-Hitachi_HTS545050A7E380_TA95123V059NEX"
                ];
                description = ''
                  Whole disks as /dev/disk/by-id/* paths (never /dev/sdX).
                  Used by storage-disks-format and storage-disks-replace.
                  Import finds the pool by name, not by this list.
                '';
                rank = 60;
              };
              keyFile = mkOption {
                type = types.str;
                default = "/root/keys/datadisk.key";
                description = ''
                  Raw 32-byte ZFS key (or base64 of those 32 bytes).
                  Used when encryption=keyfile, and when importing a pool that
                  is already encrypted. Ignored for a plaintext pool.
                  Must live on the OS disk. Not stored in the Nix store.
                  storage-disks-format --yes creates it (mode 0600) if missing.
                '';
                rank = 70;
              };
              layout = mkOption {
                type = types.enum ["mirror" "stripe"];
                default = "mirror";
                description = "vdev layout used only by storage-disks-format. mirror needs two or more devices.";
                rank = 80;
              };
              autoScrub = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable periodic zpool scrub via services.zfs.autoScrub.";
                };
                interval = mkOption {
                  type = types.str;
                  default = "*-*-* 02:00:00";
                  description = "systemd calendar expression for the scrub timer.";
                };
              };
            }
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                ZFS pool on attached disks for Sanoid (destPrefix =
                <poolName>/<dataset>). encryption=keyfile (default) is
                AES-256-GCM with keyFile. encryption=none is plaintext.

                Boot imports the pool only when the disks are there, then
                unlocks and mounts it. A missing disk or a missing key is
                logged and skipped: it does not fail boot, and it does not
                ask for a passphrase. The import is retried in the background.

                To put new disks into service: set devices to stable
                /dev/disk/by-id/* paths, choose encryption and layout, set
                mode=format, apply, then run `storage-disks-format --yes`.
                That wipes those disks, creates the pool and dataset, and
                mounts them. Set mode back to import and apply.
                Replace a dead mirror disk with:
                storage-disks-replace --yes /dev/disk/by-id/<new>.
              '';
            };
        };
        default = {};
        description = "ZFS pool on attached disks for backups";
      };
    };
}
