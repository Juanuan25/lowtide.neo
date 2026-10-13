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
                  Import: attach the pool when the disks are there. Nothing is wiped.
                  Format: the next Activate wipes poolName and creates it again
                  with the layout and encryption set here, then mounts it.
                  No shell command. After it shows done, set this back to Import
                  and Activate again.
                '';
                rank = 10;
                ui = lib.neo.ui.mkUi {
                  label = "What Activate should do";
                  choiceLabels = {
                    import = "Import (keep the data)";
                    format = "Format (wipe and create)";
                  };
                };
              };
              formatSerial = mkOption {
                type = types.ints.unsigned;
                default = 1;
                description = ''
                  Format runs once for this number. Activate again with the same
                  number does not wipe a second time. Raise it by one, leave mode
                  on Format, and Activate to wipe again.
                '';
                rank = 12;
                ui = lib.neo.ui.mkUi {label = "Format number";};
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
                ui = lib.neo.ui.mkUi {
                  label = "Encryption";
                  choiceLabels = {
                    keyfile = "Encrypted (key file)";
                    none = "Not encrypted";
                  };
                };
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
                helper = lib.neo.mkHelper {
                  id = "storage-disks-list";
                  kind = "button";
                  label = "Find disks";
                  description = "Replace this list with whole disks that are plugged in, except the disk the system is running from.";
                  apply = "set";
                  script = ./list-disks.sh;
                  inputs = [];
                };
                ui = lib.neo.ui.mkUi {label = "Disks";};
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
                ui = lib.neo.ui.mkUi {
                  label = "Layout";
                  choiceLabels = {
                    mirror = "Mirror (copies on every disk)";
                    stripe = "Stripe (one copy, uses all disks)";
                  };
                };
              };
              replaceWith = mkOption {
                type = types.str;
                default = "";
                description = ''
                  By-id path of a replacement disk. Leave empty to do nothing.
                  Set it and Activate to swap it in for a missing mirror disk.
                  That runs once. Clear the field afterwards.
                '';
                rank = 90;
                ui = lib.neo.ui.mkUi {label = "Replace a dead disk with";};
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
            // lib.neo.mkSystemdUnits [
              "storage-disks-ensure-imported"
              "storage-disks-format"
              "storage-disks-replace"
            ]
            // lib.neo.mkSystemdTimers ["storage-disks-ensure-imported"]
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                Manage the backup disks from this page. No shell commands.

                Find disks fills the disk list (the system disk is skipped).
                Pick encrypted or not, and mirror or stripe.

                Import keeps whatever is already on the disks and mounts it
                when they are plugged in. A missing disk does not stop boot.
                The Status tab can start that import, and it also retries itself.

                Format wipes the pool named above and creates it again.
                Set What Activate should do to Format, then press Activate.
                Watch Status until the format unit says done, set it back to
                Import, and Activate again. The same format number will not
                wipe twice. Raise Format number to wipe again.

                Sanoid should use <poolName>/<dataset> as destPrefix
                (default datadisk/backups).
              '';
            };
        };
        default = {};
        description = "ZFS pool on attached disks for backups";
      };
    };
}
