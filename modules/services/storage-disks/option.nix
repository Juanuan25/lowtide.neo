# Options: import the existing datadisk mirror (or format new disks).
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
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
                  import: import poolName on every boot (never wipes disks).
                  format: unlocks storage-disks-format --yes only; never runs on activate.
                '';
                rank = 10;
              };
              poolName = mkOption {
                type = types.str;
                default = "datadisk";
                description = "ZFS pool name. Must match `zpool import` (this host: datadisk).";
                rank = 20;
              };
              dataset = mkOption {
                type = types.str;
                default = "backups";
                description = "Dataset under the pool (<poolName>/<dataset>).";
                rank = 30;
              };
              poolMountPoint = mkOption {
                type = types.str;
                default = "/mnt/external_ssd";
                description = "Native ZFS mountpoint of the pool root. Matches the existing datadisk property.";
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
                  Mirror members as /dev/disk/by-id/* paths (never /dev/sdX).
                  Used by storage-disks-replace and by format. Import is by pool name.
                '';
                rank = 60;
              };
              keyFile = mkOption {
                type = types.str;
                default = "/root/keys/datadisk.key";
                description = ''
                  Raw ZFS wrapping key for poolName (keylocation=file://…).
                  Must exist on this host; not stored in the nix store.
                  Loaded after import so native mounts work across reboot.
                '';
                rank = 70;
              };
              layout = mkOption {
                type = types.enum ["mirror" "stripe"];
                default = "mirror";
                description = "vdev layout used only when mode=format. mirror needs two or more devices.";
                rank = 80;
              };
              autoScrub = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable periodic zpool scrub via services.zfs.autoScrub.";
                };
                interval = mkOption {
                  type = types.str;encrypted datadisk mirror on boot (force
                import, by-id, USB retry, load-key from keyFile). Native mounts
                stay at /mnt/external_ssd — no NixOS fileSystems entry, so a
                missing USB disk cannot block boot. Replace a dead disk with:
               
            }
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                Imports the existing datadisk mirror on boot (force import, by-id
                device nodes, USB retry). Keeps native ZFS mounts at
                /mnt/external_ssd and /mnt/external_ssd/backups — no NixOS
                fileSystems entry, so a missing USB disk cannot block boot.
                Replace a dead disk with: storage-disks-replace --yes /dev/disk/by-id/<new>.
                mode=format only unlocks storage-disks-format --yes.
              '';
            };
        };
        default = {};
        description = "ZFS pool on attached disks for backups";
      };
    };
}
