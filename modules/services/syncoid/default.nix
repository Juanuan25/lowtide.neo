# Implementation: NixOS services.syncoid replication job.
{...}: {
  flake.modules.nixos.syncoid = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.syncoid;
      disks = config.neo.services.storage-disks;
      sanoid = config.neo.services.sanoid or {};
      source =
        if cfg.source != ""
        then cfg.source
        else sanoid.dataset or "zroot";
      target =
        if cfg.target != ""
        then cfg.target
        else if disks.enabled or false
        then "${disks.poolName}/${disks.dataset}"
        else "";
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = source != "";
            message = "neo.services.syncoid: source must be set (default is zroot).";
          }
          {
            assertion = target != "";
            message = ''
              neo.services.syncoid: target must be set, or enable
              neo.services.storage-disks so datadisk/backups can be used.
            '';
          }
        ];

        services.syncoid = {
          enable = true;
          interval = cfg.interval;
          sshKey =
            if cfg.sshKey != ""
            then cfg.sshKey
            else null;
          commands.backup = {
            inherit source target;
            recursive = cfg.recursive;
            extraArgs = cfg.extraArgs;
          };
        };

        systemd.services.syncoid-backup = {
          after =
            optional (disks.enabled or false) "storage-disks-ensure-imported.service"
            ++ optional (sanoid.enabled or false) "sanoid.service";
          requires = optional (disks.enabled or false) "storage-disks-ensure-imported.service";
        };
      };
    };
}
