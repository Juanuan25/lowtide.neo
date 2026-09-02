# Implementation: NixOS services.sanoid snapshot policy.
{...}: {
  flake.modules.nixos.sanoid = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.sanoid;
      dataset = cfg.dataset;
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = dataset != "";
            message = "neo.services.sanoid: dataset must be set (default is zroot).";
          }
        ];

        services.sanoid = {
          enable = true;
          interval = cfg.interval;
          datasets.${dataset} = {
            use_template = ["backup"];
            recursive = cfg.recursive;
          };
          templates.backup = {
            hourly = cfg.hourly;
            daily = cfg.daily;
            monthly = cfg.monthly;
            yearly = cfg.yearly;
            autosnap = cfg.autosnap;
            autoprune = cfg.autoprune;
          };
        };
      };
    };
}
