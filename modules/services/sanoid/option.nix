# Options: Sanoid ZFS snapshot policy.
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
              dataset = mkOption {
                type = types.str;
                default = "zroot";
                example = "zroot";
                description = "ZFS dataset to snapshot (this host: zroot, the system pool).";
                rank = 10;
              };
              recursive = mkOption {
                type = types.bool;
                default = true;
                description = "Also snapshot child datasets.";
                rank = 20;
              };
              interval = mkOption {
                type = types.str;
                default = "hourly";
                description = "systemd calendar expression for how often sanoid runs.";
                rank = 30;
              };
              hourly = mkOption {
                type = types.ints.unsigned;
                default = 24;
                description = "Number of hourly snapshots to keep.";
                rank = 40;
              };
              daily = mkOption {
                type = types.ints.unsigned;
                default = 14;
                description = "Number of daily snapshots to keep.";
                rank = 50;
              };
              monthly = mkOption {
                type = types.ints.unsigned;
                default = 6;
                description = "Number of monthly snapshots to keep.";
                rank = 60;
              };
              yearly = mkOption {
                type = types.ints.unsigned;
                default = 0;
                description = "Number of yearly snapshots to keep.";
                rank = 70;
              };
              autosnap = mkOption {
                type = types.bool;
                default = true;
                description = "Take snapshots automatically.";
                rank = 80;
              };
              autoprune = mkOption {
                type = types.bool;
                default = true;
                description = "Prune old snapshots automatically.";
                rank = 90;
              };
            }
            // lib.neo.mkSystemdUnits ["sanoid"]
            // lib.neo.mkServiceMeta {
              category = "Storage";
              icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/truenas.svg";
              description = ''
                Runs Sanoid on a timer to take and prune ZFS snapshots of zroot
                (the system pool). Pair with syncoid to replicate those snapshots
                onto datadisk/backups. Set how many hourly/daily/monthly/yearly
                snapshots to keep.
              '';
              projectUrl = "https://github.com/jimsalterjrs/sanoid";
              githubUrl = "https://github.com/jimsalterjrs/sanoid";
            };
        };
        default = {};
        description = "Sanoid ZFS snapshot policy";
      };
    };
}
