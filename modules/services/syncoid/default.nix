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
      source =
        if cfg.source != ""
        then cfg.source
        else if disks.enabled or false
        then "${disks.poolName}/${disks.dataset}"
        else "";
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = source != "";
            message = ''
              neo.services.syncoid: source must be set, or enable
              neo.services.storage-disks so the backup dataset can be used.
            '';
          }
          {
            assertion = cfg.target != "";
            message = "neo.services.syncoid: target must be set to a local or remote dataset.";
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
            inherit source;
            target = cfg.target;
            recursive = cfg.recursive;
            extraArgs = cfg.extraArgs;
          };
        };
      };
    };
}
