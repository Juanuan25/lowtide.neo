# Implementation: import an existing ZFS pool, or format listed disks into a new one.
{...}: {
  flake.modules.nixos.storage-disks = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.storage-disks;
      devices = cfg.devices;
      devicesShell = escapeShellArgs devices;
      pool = cfg.poolName;
      dataset = cfg.dataset;

      formatScript = pkgs.writeShellScriptBin "storage-disks-format" ''
        set -euo pipefail
        pool="${pool}"
        dataset="${dataset}"
        layout="${cfg.layout}"
        pool_mnt="${cfg.poolMountPoint}"
        ds_mnt="${cfg.mountPoint}"
        devices=(${devicesShell})

        if [ ${toString (length devices)} -eq 0 ]; then
          echo "neo.services.storage-disks.devices is empty." >&2
          exit 1
        fi

        for d in "''${devices[@]}"; do
          if [ ! -b "$d" ] && [ ! -e "$d" ]; then
            echo "Device $d not found. Use /dev/disk/by-id/* paths." >&2
            exit 1
          fi
        done

        if zpool list "$pool" >/dev/null 2>&1; then
          echo "zpool $pool is already imported. Nothing to format." >&2
          exit 1
        fi

        existing=$(zpool import -d /dev/disk/by-id 2>/dev/null | awk '/^[[:space:]]*pool:/{print $2}' | head -n1 || true)
        if [ -n "$existing" ]; then
          echo "An exportable zpool named '$existing' is already on these disks." >&2
          echo "Set mode=import and poolName=\"$existing\" instead of formatting." >&2
          exit 1
        fi

        if [ "''${1:-}" != "--yes" ]; then
          echo "This DESTROYS all data on:" >&2
          printf '  %s\n' "''${devices[@]}" >&2
          echo "and creates zpool '$pool' (layout=$layout)." >&2
          echo "Re-run as: storage-disks-format --yes" >&2
          exit 1
        fi

        case "$layout" in
          mirror)
            if [ "''${#devices[@]}" -lt 2 ]; then
              echo "layout=mirror needs at least two devices." >&2
              exit 1
            fi
            zpool create -o ashift=12 -O mountpoint="$pool_mnt" "$pool" mirror "''${devices[@]}"
            ;;
          stripe)
            zpool create -o ashift=12 -O mountpoint="$pool_mnt" "$pool" "''${devices[@]}"
            ;;
          *)
            echo "Unknown layout $layout" >&2
            exit 1
            ;;
        esac

        zfs create -o mountpoint="$ds_mnt" "$pool/$dataset"
        echo "Created $pool/$dataset at $ds_mnt."
      '';

      loadKey = ''
        keyfile="${cfg.keyFile}"
        status=$(zfs get -H -o value keystatus "$pool" 2>/dev/null || true)
        if [ "$status" = "available" ]; then
          :
        elif [ -z "$keyfile" ] || [ ! -r "$keyfile" ]; then
          echo "ZFS key for $pool not loaded (missing $keyfile)." >&2
          exit 1
        else
          size=$(wc -c < "$keyfile" | tr -d ' ')
          if [ "$size" = "32" ]; then
            zfs load-key -L "file://$keyfile" "$pool"
          else
            tmp=$(mktemp)
            if base64 -d "$keyfile" > "$tmp" 2>/dev/null && [ "$(wc -c < "$tmp" | tr -d ' ')" = "32" ]; then
              zfs load-key -L "file://$tmp" "$pool"
            else
              rm -f "$tmp"
              echo "ZFS key $keyfile is not a 32-byte raw key (got $size bytes)." >&2
              exit 1
            fi
            rm -f "$tmp"
          fi
        fi
      '';

      importScript = pkgs.writeShellScriptBin "storage-disks-import" ''
        set -euo pipefail
        pool="${pool}"
        dataset="${dataset}"

        if zpool list "$pool" >/dev/null 2>&1; then
          echo "zpool $pool already imported."
        else
          echo "Importing zpool $pool (force, by-id)..."
          zpool import -f -d /dev/disk/by-id "$pool"
        fi

        ${loadKey}

        if ! zfs list "$pool/$dataset" >/dev/null 2>&1; then
          echo "Dataset $pool/$dataset does not exist." >&2
          zfs list -r "$pool" >&2
          exit 1
        fi

        zfs mount -a || true
        echo "Imported $pool. Native mounts: ${cfg.poolMountPoint} and ${cfg.mountPoint}."
      '';

      replaceScript = pkgs.writeShellScriptBin "storage-disks-replace" ''
        set -euo pipefail
        pool="${pool}"
        yes=0
        args=()
        for a in "$@"; do
          if [ "$a" = "--yes" ]; then
            yes=1
          else
            args+=("$a")
          fi
        done

        if ! zpool list "$pool" >/dev/null 2>&1; then
          echo "zpool $pool is not imported. Run storage-disks-import first." >&2
          exit 1
        fi

        old=""
        new=""
        case "''${#args[@]}" in
          1)
            new="''${args[0]}"
            old=$(zpool status -P "$pool" | awk '
              /UNAVAIL|FAULTED|OFFLINE|REMOVED/ && $1 ~ /^\// { print $1; exit }
            ')
            if [ -z "$old" ]; then
              echo "No UNAVAIL/FAULTED/OFFLINE disk in $pool. Pass both old and new by-id paths:" >&2
              echo "  storage-disks-replace --yes /dev/disk/by-id/<old> /dev/disk/by-id/<new>" >&2
              zpool status "$pool" >&2
              exit 1
            fi
            ;;
          2)
            old="''${args[0]}"
            new="''${args[1]}"
            ;;
          *)
            echo "Replace a dead mirror member (does not wipe the surviving disk):" >&2
            echo "  storage-disks-replace --yes /dev/disk/by-id/<new-disk>" >&2
            echo "  storage-disks-replace --yes /dev/disk/by-id/<old> /dev/disk/by-id/<new>" >&2
            echo >&2
            zpool status "$pool" >&2
            exit 1
            ;;
        esac

        if [ ! -e "$new" ] && [ ! -b "$new" ]; then
          echo "New device $new not found. Use /dev/disk/by-id/*." >&2
          exit 1
        fi

        if [ "$yes" != 1 ]; then
          echo "This will replace $old with $new in mirror $pool." >&2
          echo "The new disk will be resilvered. Re-run with --yes." >&2
          exit 1
        fi

        zpool replace "$pool" "$old" "$new"
        zpool status "$pool"
        echo "Resilver started. Watch with: watch -n 5 zpool status $pool"
      '';

      ensureImported = pkgs.writeShellScript "storage-disks-ensure-imported" ''
        set -euo pipefail
        pool="${pool}"
        if ! zpool list "$pool" >/dev/null 2>&1; then
          zpool import -f -d /dev/disk/by-id "$pool"
        fi
        ${loadKey}
        zfs mount "$pool" >/dev/null 2>&1 || true
        zfs mount "$pool/${dataset}" >/dev/null 2>&1 || true
        zfs mount -a >/dev/null 2>&1 || true
      '';
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = cfg.mode != "format" || devices != [];
            message = "neo.services.storage-disks: mode=format requires devices (stable /dev/disk/by-id/* paths).";
          }
          {
            assertion = cfg.mode != "format" || cfg.layout != "mirror" || length devices >= 2;
            message = "neo.services.storage-disks: layout=mirror needs at least two devices.";
          }
        ];

        boot.supportedFilesystems = ["zfs"];
        boot.zfs.extraPools = [pool];
        boot.zfs.forceImportAll = mkDefault true;
        boot.zfs.devNodes = "/dev/disk/by-id";
        boot.zfs.requestEncryptionCredentials = [pool];

        # Do not let a late USB disk stall or fail the boot target.
        systemd.services."zfs-import-${pool}" = {
          after = ["systemd-udev-settle.service"];
          serviceConfig.TimeoutStartSec = "90s";
        };

        # After /root is mounted: import, load-key, native-mount. Retries if USB is late.
        systemd.services.storage-disks-ensure-imported = {
          description = "Ensure ZFS pool ${pool} is imported, unlocked, and mounted";
          after = [
            "local-fs.target"
            "systemd-udev-settle.service"
            "zfs-import.target"
          ];
          wants = ["systemd-udev-settle.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = ensureImported;
            Restart = "on-failure";
            RestartSec = 15;
            TimeoutStartSec = 60;
          };
          unitConfig = {
            StartLimitIntervalSec = 300;
            StartLimitBurst = 12;
          };
        };

        services.zfs.autoScrub = {
          enable = cfg.autoScrub.enable;
          interval = cfg.autoScrub.interval;
        };

        environment.systemPackages =
          [importScript replaceScript]
          ++ optional (cfg.mode == "format") formatScript;
      };
    };
}

