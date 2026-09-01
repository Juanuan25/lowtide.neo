# Implementation: import/mount a ZFS mirror across two attached SSDs for backups.
{...}: {
  flake.modules.nixos.storage-disks = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.storage-disks;
      poolDataset = "${cfg.poolName}/${cfg.dataset}";
      # Destroys any data on both disks; must be run manually with --yes, never automatically.
      bootstrapScript = pkgs.writeShellScriptBin "storage-disks-bootstrap-pool" ''
        set -euo pipefail
        pool="${cfg.poolName}"
        dataset="${cfg.dataset}"
        disk1="${cfg.ssd1.device}"
        disk2="${cfg.ssd2.device}"

        if [ "''${1:-}" != "--yes" ]; then
          echo "This DESTROYS all data on $disk1 and $disk2 and creates zpool '$pool' (mirror)." >&2
          echo "Re-run as: storage-disks-bootstrap-pool --yes" >&2
          exit 1
        fi

        if zpool list "$pool" >/dev/null 2>&1; then
          echo "zpool $pool already exists, skipping zpool create" >&2
        else
          zpool create -o ashift=12 "$pool" mirror "$disk1" "$disk2"
        fi

        if ! zfs list "$pool/$dataset" >/dev/null 2>&1; then
          zfs create -o mountpoint=legacy "$pool/$dataset"
        fi

        echo "Done. Re-run nixos-rebuild switch (or neo activate) to mount $pool/$dataset."
      '';
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = cfg.ssd1.device != "" && cfg.ssd2.device != "";
            message = ''
              neo.services.storage-disks: both ssd1.device and ssd2.device must be set
              to a stable /dev/disk/by-id/* path. Run `ls -l /dev/disk/by-id/` on the
              server to find them.
            '';
          }
        ];

        boot.supportedFilesystems = ["zfs"];

        services.zfs.autoScrub = {
          enable = cfg.autoScrub.enable;
          interval = cfg.autoScrub.interval;
        };

        fileSystems.${cfg.mountPoint} = {
          device = poolDataset;
          fsType = "zfs";
          options = ["zfsutil"];
        };

        environment.systemPackages = [bootstrapScript];
      };
    };
}

