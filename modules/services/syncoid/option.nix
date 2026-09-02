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
                default = "zroot";
                example = "zroot";
                description = "Source ZFS dataset to replicate (this host: zroot). Empty uses neo.services.sanoid.dataset.";
                rank = 10;
              };
              target = mkOption {
                type = types.str;
                default = "";
                example = "datadisk/backups";
                description = "Target dataset. Empty uses storage-disks poolName/dataset (datadisk/backups). Local (pool/dataset) or remote (user@host:pool/dataset).";
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
                Runs Syncoid on a timer to replicate zroot (Sanoid snapshots)
                onto datadisk/backups. extraArgs defaults to --no-sync-snap so
                Sanoid snapshots are used instead of creating syncoid's own.
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
