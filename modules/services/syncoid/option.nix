# Options: Syncoid ZFS replication.
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
{...}: {
  flake.modules.nixos.syncoid-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.syncoid = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Syncoid periodic ZFS replication" {
                rank = 0;
              };
              source = mkOption {
                type = types.str;
                default = "";
                example = "backup/backups";
                description = "Source ZFS dataset. Empty uses storage-disks poolName/dataset when that service is enabled.";
                rank = 10;
              };
              target = mkOption {
                type = types.str;
                default = "";
                example = "user@host:pool/backups";
                description = "Target dataset. Local (pool/dataset) or remote (user@host:pool/dataset).";
                rank = 20;
              };
              recursive = mkOption {
                type = types.bool;
                default = true;
                description = "Also replicate child datasets.";
                rank = 30;
              };
              interval = mkOption {
                type = types.str;
                default = "*-*-* 03:00:00";
                description = "systemd calendar expression for how often syncoid runs.";
                rank = 40;
              };
              sshKey = mkOption {
                type = types.str;
                default = "";
                example = "/var/lib/syncoid/id_ed25519";
                description = "SSH private key for remote targets. Leave empty for local replication.";
                rank = 50;
              };
              extraArgs = mkOption {
                type = types.listOf types.str;
                default = ["--no-sync-snap"];
                example = ["--no-sync-snap" "--create-bookmark"];
                description = "Extra syncoid flags. --no-sync-snap uses Sanoid snapshots instead of creating its own.";
                rank = 60;
              };
            }
            // lib.neo.mkSystemdUnits ["syncoid-backup"]
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                Runs Syncoid on a timer to replicate a ZFS dataset (typically the
                storage-disks backup pool) to another local or remote dataset.
                Pair with sanoid so snapshots exist before replication; extraArgs
                defaults to --no-sync-snap so Sanoid snapshots are used.
              '';
              projectUrl = "https://github.com/jimsalterjrs/sanoid";
              githubUrl = "https://github.com/jimsalterjrs/sanoid";
            };
        };
        default = {};
        description = "Syncoid ZFS replication";
      };
    };
}
