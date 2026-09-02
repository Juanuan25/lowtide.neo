# Options: Sanoid snapshots + optional syncoid replicate onto destPrefix.
# Operator values live in Neo settings.toml / the web UI, not in this plugin.
{...}: {
  flake.modules.nixos.sanoid-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.sanoid = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Sanoid periodic ZFS snapshots and pruning" {
                rank = 0;
              };
              datasets = mkOption {
                type = types.listOf types.str;
                default = ["zroot"];
                example = ["zroot" "rpool" "bpool" "images"];
                description = ''
                  Source datasets/pools to snapshot with the production template
                  (autosnap). Each is also registered under destPrefix with the
                  backup template (prune only, no local snapshots).
                '';
                rank = 10;
              };
              destPrefix = mkOption {
                type = types.str;
                default = "datadisk/backups";
                example = "datadisk/backups";
                description = ''
                  Parent dataset for prune-only copies and syncoid targets.
                  Each source `pool` becomes <destPrefix>/<pool>
                  (e.g. zroot -> datadisk/backups/zroot).
                '';
                rank = 20;
              };
              recursive = mkOption {
                type = types.bool;
                default = true;
                description = "Also snapshot (and replicate) child datasets.";
                rank = 30;
              };
              interval = mkOption {
                type = types.str;
                default = "hourly";
                description = "systemd calendar expression for how often sanoid runs.";
                rank = 40;
              };
              replicate = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = ''
                    After Sanoid finishes, syncoid --recursive --no-sync-snap each
                    source onto <destPrefix>/<source> (post_snapshot_script).
                  '';
                  rank = 45;
                };
                sendRaw = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Pass --send-raw (only when the *source* is ZFS-encrypted).
                    Leave off when sources are plaintext and only datadisk is encrypted.
                  '';
                  rank = 46;
                };
                extraArgs = mkOption {
                  type = types.listOf types.str;
                  default = ["--no-sync-snap"];
                  example = ["--no-sync-snap" "--create-bookmark"];
                  description = "Extra syncoid flags.";
                  rank = 47;
                };
              };
              production = {
                frequently = mkOption {
                  type = types.ints.unsigned;
                  default = 0;
                  description = "Frequent (15-min) snapshots to keep on sources.";
                  rank = 50;
                };
                hourly = mkOption {
                  type = types.ints.unsigned;
                  default = 36;
                  description = "Hourly snapshots to keep on sources.";
                  rank = 51;
                };
                daily = mkOption {
                  type = types.ints.unsigned;
                  default = 30;
                  description = "Daily snapshots to keep on sources.";
                  rank = 52;
                };
                monthly = mkOption {
                  type = types.ints.unsigned;
                  default = 3;
                  description = "Monthly snapshots to keep on sources.";
                  rank = 53;
                };
                yearly = mkOption {
                  type = types.ints.unsigned;
                  default = 0;
                  description = "Yearly snapshots to keep on sources.";
                  rank = 54;
                };
                autosnap = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Take snapshots on source datasets.";
                  rank = 55;
                };
                autoprune = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Prune old snapshots on source datasets.";
                  rank = 56;
                };
              };
              backup = {
                frequently = mkOption {
                  type = types.ints.unsigned;
                  default = 0;
                  description = "Frequent snapshots to keep on dest datasets.";
                  rank = 60;
                };
                hourly = mkOption {
                  type = types.ints.unsigned;
                  default = 30;
                  description = "Hourly snapshots to keep on dest datasets.";
                  rank = 61;
                };
                daily = mkOption {
                  type = types.ints.unsigned;
                  default = 30;
                  description = "Daily snapshots to keep on dest datasets.";
                  rank = 62;
                };
                monthly = mkOption {
                  type = types.ints.unsigned;
                  default = 6;
                  description = "Monthly snapshots to keep on dest datasets.";
                  rank = 63;
                };
                yearly = mkOption {
                  type = types.ints.unsigned;
                  default = 0;
                  description = "Yearly snapshots to keep on dest datasets.";
                  rank = 64;
                };
                autosnap = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Do not snapshot dests locally; syncoid replicates them in.";
                  rank = 65;
                };
                autoprune = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Prune old snapshots on dest datasets.";
                  rank = 66;
                };
                hourly_warn = mkOption {
                  type = types.ints.unsigned;
                  default = 2880;
                  description = "Minutes before an overdue hourly snapshot is a warning.";
                  rank = 67;
                };
                hourly_crit = mkOption {
                  type = types.ints.unsigned;
                  default = 3600;
                  description = "Minutes before an overdue hourly snapshot is critical.";
                  rank = 68;
                };
                daily_warn = mkOption {
                  type = types.ints.unsigned;
                  default = 48;
                  description = "Hours before an overdue daily snapshot is a warning.";
                  rank = 69;
                };
                daily_crit = mkOption {
                  type = types.ints.unsigned;
                  default = 60;
                  description = "Hours before an overdue daily snapshot is critical.";
                  rank = 70;
                };
              };
            }
            // lib.neo.mkSystemdUnits ["sanoid" "syncoid-backup"]
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                Sanoid snapshots listed source datasets with a production template
                (autosnap + prune). Matching datasets under destPrefix (default
                datadisk/backups/<source>) use a backup template: prune and monitor
                only. replicate.enable (default on) then syncoid --recursive
                --no-sync-snap each source onto those dests after the run
                (post_snapshot_script). No --send-raw: zroot is plaintext, datadisk
                is encrypted.
              '';
              projectUrl = "https://github.com/jimsalterjrs/sanoid";
              githubUrl = "https://github.com/jimsalterjrs/sanoid";
            };
        };
        default = {};
        description = "Sanoid ZFS snapshot policy and syncoid replication";
      };
    };
}
