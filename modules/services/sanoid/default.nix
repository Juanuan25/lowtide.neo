# Implementation: Sanoid snapshots, then optional syncoid onto destPrefix.
{...}: {
  flake.modules.nixos.sanoid = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.sanoid;
      disks = config.neo.services.storage-disks or {};
      leaf = ds: last (splitString "/" ds);
      destPrefix = cfg.destPrefix;
      destOf = ds: "${destPrefix}/${leaf ds}";
      sourceDatasets = cfg.datasets;
      destDatasets = map destOf sourceDatasets;
      mkDs = template: ds: {
        name = ds;
        value = {
          use_template = [template];
          recursive = cfg.recursive;
        };
      };
      flags =
        optional cfg.recursive "--recursive"
        ++ optional cfg.replicate.sendRaw "--send-raw"
        ++ cfg.replicate.extraArgs;
      syncScript = pkgs.writeShellScript "syncoid-backup" ''
        set -euo pipefail
        export HOME=/root
        ${concatMapStringsSep "\n" (ds: ''
            echo "syncoid ${ds} -> ${destOf ds}"
            ${pkgs.sanoid}/bin/syncoid ${escapeShellArgs flags} ${escapeShellArg ds} ${escapeShellArg (destOf ds)}
          '')
          sourceDatasets}
      '';
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = sourceDatasets != [];
            message = "neo.services.sanoid: datasets must list at least one source pool/dataset.";
          }
          {
            assertion = destPrefix != "";
            message = "neo.services.sanoid: destPrefix must be set (default is datadisk/backups).";
          }
        ];

        services.sanoid = {
          enable = true;
          interval = cfg.interval;
          datasets =
            listToAttrs (map (mkDs "production") sourceDatasets)
            // listToAttrs (map (mkDs "backup") destDatasets);
          templates.production = {
            frequently = cfg.production.frequently;
            hourly = cfg.production.hourly;
            daily = cfg.production.daily;
            monthly = cfg.production.monthly;
            yearly = cfg.production.yearly;
            autosnap = cfg.production.autosnap;
            autoprune = cfg.production.autoprune;
          };
          templates.backup = {
            frequently = cfg.backup.frequently;
            hourly = cfg.backup.hourly;
            daily = cfg.backup.daily;
            monthly = cfg.backup.monthly;
            yearly = cfg.backup.yearly;
            autosnap = cfg.backup.autosnap;
            autoprune = cfg.backup.autoprune;
            hourly_warn = cfg.backup.hourly_warn;
            hourly_crit = cfg.backup.hourly_crit;
            daily_warn = cfg.backup.daily_warn;
            daily_crit = cfg.backup.daily_crit;
          };
        };

        systemd.services.syncoid-backup = mkIf cfg.replicate.enable {
          description = "Syncoid replication of Sanoid snapshots to ${destPrefix}";
          after = optional (disks.enabled or false) "storage-disks-ensure-imported.service";
          requires = optional (disks.enabled or false) "storage-disks-ensure-imported.service";
          path = [
            "/run/booted-system/sw/bin"
            pkgs.zfs
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${syncScript}";
          };
        };

        systemd.services.sanoid = mkIf cfg.replicate.enable {
          onSuccess = ["syncoid-backup.service"];
        };
      };
    };
}
