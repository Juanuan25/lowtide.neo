# Options: two attached SSDs as a ZFS mirror, dataset mounted for backups.
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
              enabled = mkEnableOption "ZFS mirror across two attached SSDs, mounted as the backup destination" {
                rank = 0;
              };
              poolName = mkOption {
                type = types.str;
                default = "backup";
                description = "Name of the zpool spanning both disks.";
              };
              dataset = mkOption {
                type = types.str;
                default = "backups";
                description = "Dataset created under the pool (i.e. <poolName>/<dataset>).";
              };
              mountPoint = mkOption {
                type = types.str;
                default = "/mnt/backups";
                description = "Where <poolName>/<dataset> is mounted (managed by NixOS, not ZFS's own mountpoint property).";
              };
              hostId = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "8f2a91c3";
                description = ''
                  Value for networking.hostId, required by ZFS to prevent a pool being
                  imported on the wrong machine. Generate once with:
                  head -c4 /dev/urandom | od -A none -t x4 | tr -d ' '
                  Must stay the same for the lifetime of this pool.
                '';
              };
              ssd1 = {
                device = mkOption {
                  type = types.str;
                  default = "";
                  example = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_S5XXXXXXXXXXXX";
                  description = ''
                    Stable device path for the first disk (currently /dev/sdb).
                    Always use /dev/disk/by-id/*, never /dev/sdX (letters can change
                    across reboots). List candidates with: ls -l /dev/disk/by-id/
                  '';
                };
              };
              ssd2 = {
                device = mkOption {
                  type = types.str;
                  default = "";
                  example = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_S5YYYYYYYYYYYY";
                  description = "Stable device path for the second disk (currently /dev/sdc). See ssd1.device.";
                };
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
                Configures ZFS import/mount for a mirrored pool across two attached
                SSDs. This does not take snapshots or replicate: enable the sanoid
                and syncoid services for backup policy. Pool creation is destructive
                and is not automatic; a guarded `storage-disks-bootstrap-pool --yes`
                script creates the pool/dataset once after the by-id paths are set.
              '';
            };
        };
        default = {};
        description = "ZFS mirror across two attached SSDs for backups";
      };
    };
}
