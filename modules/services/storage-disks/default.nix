# Import an attached ZFS pool, or format listed disks into a new one.
#
# Boot contract: this pool is optional. It is not in boot.zfs.extraPools and
# it is not a NixOS fileSystems entry, so a missing disk cannot fail
# zfs-import.target or local-fs.target. The ensure script always exits 0.
# Do not request a passphrase at boot — headless machines must come up.
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
      pool = escapeShellArg cfg.poolName;
      dataset = escapeShellArg cfg.dataset;
      keyFile = escapeShellArg cfg.keyFile;
      poolMnt = escapeShellArg cfg.poolMountPoint;
      dsMnt = escapeShellArg cfg.mountPoint;
      layout = escapeShellArg cfg.layout;
      encryption = escapeShellArg cfg.encryption;
      mode = escapeShellArg cfg.mode;
      formatStamp = builtins.hashString "sha256" (concatStringsSep "\n" [
        cfg.poolName
        cfg.dataset
        cfg.layout
        cfg.encryption
        (toString cfg.formatSerial)
        cfg.poolMountPoint
        cfg.mountPoint
        (concatStringsSep "\n" cfg.devices)
      ]);
      replaceStamp = builtins.hashString "sha256" (concatStringsSep "\n" [
        cfg.poolName
        cfg.replaceWith
      ]);

      # Shared by format/import/replace/ensure. $pool is the shell variable.
      loadKeyFn = ''
        load_key() {
          keyfile="$1"
          if [ -z "$keyfile" ] || [ ! -r "$keyfile" ]; then
            echo "storage-disks: encryption key not readable (''${keyfile:-unset})." >&2
            return 1
          fi
          size=$(wc -c < "$keyfile" | tr -d ' ')
          if [ "$size" = "32" ]; then
            zfs load-key -L "file://$keyfile" "$pool"
            return $?
          fi
          tmp=$(mktemp)
          if base64 -d "$keyfile" > "$tmp" 2>/dev/null && [ "$(wc -c < "$tmp" | tr -d ' ')" = "32" ]; then
            zfs load-key -L "file://$tmp" "$pool"
            rc=$?
            rm -f "$tmp"
            return $rc
          fi
          rm -f "$tmp"
          echo "storage-disks: $keyfile is not a 32-byte raw key or base64 of one (got $size bytes)." >&2
          return 1
        }
      '';

      formatScript = pkgs.writeShellScriptBin "storage-disks-format" ''
        set -euo pipefail
        pool=${pool}
        dataset=${dataset}
        layout=${layout}
        encryption=${encryption}
        mode=${mode}
        pool_mnt=${poolMnt}
        ds_mnt=${dsMnt}
        keyfile=${keyFile}
        devices=(${devicesShell})

        if [ "$(id -u)" -ne 0 ]; then
          echo "storage-disks-format must run as root." >&2
          exit 1
        fi

        if [ "$mode" != "format" ]; then
          echo "storage-disks-format is locked (mode=$mode)." >&2
          echo "This wipes the disks below and creates zpool '$pool'." >&2
          echo "Set neo.services.storage-disks.mode = \"format\", apply, then re-run:" >&2
          echo "  storage-disks-format --yes" >&2
          exit 1
        fi

        if [ ${toString (length devices)} -eq 0 ]; then
          echo "neo.services.storage-disks.devices is empty." >&2
          exit 1
        fi

        for d in "''${devices[@]}"; do
          if [ ! -b "$d" ] && [ ! -e "$d" ]; then
            echo "Device $d not found. Use /dev/disk/by-id/* paths." >&2
            exit 1
          fi
          # ZFS mounts of this pool are expected. Anything else means the disk
          # is in use by a different filesystem.
          while read -r mp; do
            [ -n "$mp" ] || continue
            case "$mp" in
              "$pool_mnt"|"$ds_mnt"|"$pool_mnt"/*|"$ds_mnt"/*) ;;
              *)
                echo "Device $d is mounted at $mp, not under $pool_mnt. Refusing to format." >&2
                exit 1
                ;;
            esac
          done < <(lsblk -no MOUNTPOINT "$d" 2>/dev/null || true)
        done

        # Which imported pool, if any, is using this disk (whole disk or its ZFS partition).
        pool_of_device() {
          dev="$1"
          real=$(readlink -f "$dev" || echo "$dev")
          for p in $(zpool list -H -o name 2>/dev/null); do
            for v in $(zpool status -P "$p" 2>/dev/null | awk '$1 ~ /^\// { print $1 }'); do
              case "$v" in
                "$dev"|"$real"|"$dev"-part*|"$dev"p[0-9]*|"$real"[0-9]*|"$real"p[0-9]*)
                  echo "$p"
                  return 0
                  ;;
              esac
            done
          done
          return 1
        }

        pool_is_importable() {
          zpool import -d /dev/disk/by-id 2>/dev/null | awk -v p="$pool" '$1 == "pool:" && $2 == p { found = 1 } END { exit !found }'
        }

        for d in "''${devices[@]}"; do
          owner=$(pool_of_device "$d" || true)
          if [ -n "$owner" ] && [ "$owner" != "$pool" ]; then
            echo "Device $d is part of imported pool '$owner', not '$pool'." >&2
            echo "Refusing to format a disk that belongs to a different pool." >&2
            zpool status "$owner" >&2
            exit 1
          fi
        done

        rootpool=""
        if findmnt -n -t zfs / >/dev/null 2>&1; then
          rootpool=$(findmnt -n -o SOURCE / | cut -d/ -f1)
        fi
        if [ -n "$rootpool" ] && [ "$rootpool" = "$pool" ]; then
          echo "Refusing to format: '$pool' is the root pool." >&2
          exit 1
        fi

        if [ "$layout" = "mirror" ] && [ "''${#devices[@]}" -lt 2 ]; then
          echo "layout=mirror needs at least two devices." >&2
          exit 1
        fi

        existing=0
        if zpool list "$pool" >/dev/null 2>&1 || pool_is_importable; then
          existing=1
        fi

        if [ "''${1:-}" != "--yes" ]; then
          echo "This DESTROYS all data on:" >&2
          printf '  %s\n' "''${devices[@]}" >&2
          echo "and creates zpool '$pool' (layout=$layout, encryption=$encryption)." >&2
          echo "Dataset $pool/$dataset will be mounted at $ds_mnt." >&2
          if [ "$existing" = 1 ]; then
            echo "Existing pool '$pool' will be destroyed first, including any encrypted data on it." >&2
            echo "Export alone is not enough; this command destroys it." >&2
          fi
          if [ "$encryption" = "keyfile" ]; then
            echo "Key file: $keyfile (created if it does not exist yet)." >&2
          else
            echo "The new pool will NOT be encrypted." >&2
          fi
          echo "Re-run as: storage-disks-format --yes" >&2
          exit 1
        fi

        # Stop the importer so it cannot mount the pool again under us.
        # systemctl start without --no-block deadlocks: systemd is waiting
        # for this job, and a blocking systemctl waits for systemd.
        systemctl stop --no-block storage-disks-ensure-imported.timer >/dev/null 2>&1 || true
        timeout 10 systemctl stop storage-disks-ensure-imported.service >/dev/null 2>&1 || true
        mkdir -p /run/storage-disks
        touch /run/storage-disks/formatting
        finish() {
          rm -f /run/storage-disks/formatting
          timeout 5 systemctl start --no-block storage-disks-ensure-imported.timer >/dev/null 2>&1 || true
        }
        trap finish EXIT

        # Linux cannot force-unmount a ZFS dataset another mount namespace
        # still holds (containers inherit the host mounts). Lazy-unmount in
        # each namespace, then destroy. If the kernel still says busy, only
        # a reboot can drop it. The wipe then runs before ZFS imports.
        unmount_everywhere() {
          self_ns=$(readlink /proc/self/ns/mnt 2>/dev/null || true)
          seen=" "
          for mp in "$pool_mnt" "$ds_mnt"; do
            timeout 5 umount -l "$mp" >/dev/null 2>&1 || true
          done
          for nsfile in /proc/[0-9]*/ns/mnt; do
            ns=$(readlink "$nsfile" 2>/dev/null || true)
            [ -n "$ns" ] || continue
            [ "$ns" = "$self_ns" ] && continue
            case "$seen" in
              *" $ns "*) continue ;;
            esac
            seen="$seen $ns "
            pid=''${nsfile#/proc/}
            pid=''${pid%/ns/mnt}
            for mp in "$pool_mnt" "$ds_mnt"; do
              timeout 3 nsenter -t "$pid" -m umount -l "$mp" >/dev/null 2>&1 || true
            done
          done
        }

        wipe_devices() {
          root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
          root_real=$(readlink -f "$root_src" 2>/dev/null || echo "$root_src")
          for d in "''${devices[@]}"; do
            if [ ! -e "$d" ]; then
              echo "Not attached, skipped: $d"
              continue
            fi
            real=$(readlink -f "$d" || echo "$d")
            if [ -n "$root_real" ] && [ "$real" = "$root_real" ]; then
              echo "Refusing to wipe $d: it is the root disk." >&2
              exit 1
            fi
            echo "Clearing labels on $d"
            wipefs -af "$d" || true
            while read -r part; do
              [ -n "$part" ] || continue
              [ "$part" = "$real" ] && continue
              echo "Clearing labels on $part"
              wipefs -af "$part" || true
            done < <(lsblk -lnpo NAME "$real" 2>/dev/null || true)
          done
        }

        if [ "$existing" = 1 ]; then
          if [ -z "$(zpool list -H -o name "$pool" 2>/dev/null || true)" ]; then
            echo "Importing exported pool $pool so it can be destroyed..."
            timeout 20 zpool import -f -N -o cachefile=none -d /dev/disk/by-id "$pool" || true
          fi
          echo "Unmounting $pool."
          unmount_everywhere
          echo "Destroying pool $pool. Data on it will be gone."
          if ! timeout 20 zpool destroy -f "$pool"; then
            echo "Destroy failed. Exporting $pool." >&2
            timeout 15 zpool export -f "$pool" >&2 || true
          fi
          if [ -n "$(zpool list -H -o name "$pool" 2>/dev/null || true)" ]; then
            flag=/var/lib/storage-disks/await-reboot
            mkdir -p /var/lib/storage-disks
            if [ -f "$flag" ]; then
              echo "Pool $pool is still busy after a reboot. Format stopped. Nothing more was wiped." >&2
              exit 1
            fi
            touch "$flag"
            sync
            echo "Pool $pool is still open in the kernel. Rebooting once. The disks are wiped before ZFS imports them." >&2
            systemctl reboot --no-block || true
            exit 0
          fi
        fi

        wipe_devices

        for d in "''${devices[@]}"; do
          zpool labelclear -f "$d" 2>/dev/null || true
        done

        create_args=(
          -f
          -o ashift=12
          -o autotrim=on
          -o cachefile=none
          -O compression=zstd
          -O atime=off
          -O xattr=sa
          -O mountpoint="$pool_mnt"
        )

        if [ "$encryption" = "keyfile" ]; then
          if [ -z "$keyfile" ]; then
            echo "encryption=keyfile requires neo.services.storage-disks.keyFile." >&2
            exit 1
          fi
          install -d -m 0700 "$(dirname "$keyfile")"
          if [ -e "$keyfile" ]; then
            size=$(wc -c < "$keyfile" | tr -d ' ')
            if [ "$size" != "32" ]; then
              echo "Refusing to overwrite $keyfile ($size bytes, want 32)." >&2
              echo "Move it aside or point keyFile at a new path." >&2
              exit 1
            fi
            echo "Using existing key $keyfile"
          else
            umask 077
            dd if=/dev/urandom of="$keyfile" bs=32 count=1 status=none
            chmod 600 "$keyfile"
            echo "Generated a new 32-byte key at $keyfile"
            echo "Back this file up. Without it the pool cannot be unlocked."
          fi
          create_args+=(
            -O encryption=aes-256-gcm
            -O keyformat=raw
            -O keylocation="file://$keyfile"
          )
        elif [ "$encryption" != "none" ]; then
          echo "Unknown encryption $encryption (want keyfile or none)." >&2
          exit 1
        fi

        case "$layout" in
          mirror)
            zpool create "''${create_args[@]}" "$pool" mirror "''${devices[@]}"
            ;;
          stripe)
            zpool create "''${create_args[@]}" "$pool" "''${devices[@]}"
            ;;
          *)
            echo "Unknown layout $layout" >&2
            exit 1
            ;;
        esac

        zpool set cachefile=none "$pool" || true
        zfs create -o mountpoint="$ds_mnt" "$pool/$dataset"
        zfs mount "$pool" || true
        zfs mount "$pool/$dataset"

        echo "Created $pool/$dataset ($encryption)."
        echo "  pool root: $pool_mnt"
        echo "  dataset:   $ds_mnt"
        echo "Sanoid destPrefix should be $pool/$dataset."
        echo "Set What Activate should do back to Import and Activate again."
        mkdir -p /var/lib/storage-disks
        printf '%s\n' ${escapeShellArg formatStamp} > /var/lib/storage-disks/format-stamp
        rm -f /var/lib/storage-disks/await-reboot
      '';

      importScript = pkgs.writeShellScriptBin "storage-disks-import" ''
        set -euo pipefail
        pool=${pool}
        dataset=${dataset}
        keyfile=${keyFile}

        ${loadKeyFn}

        if zpool list "$pool" >/dev/null 2>&1; then
          echo "zpool $pool already imported."
        else
          echo "Importing zpool $pool (force, by-id, no cachefile)..."
          zpool import -f -N -o cachefile=none -d /dev/disk/by-id "$pool"
        fi
        zpool set cachefile=none "$pool" || true

        enc=$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo "off")
        if [ "$enc" != "off" ] && [ "$enc" != "-" ]; then
          status=$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo "unavailable")
          if [ "$status" != "available" ]; then
            load_key "$keyfile"
          fi
        fi

        if ! zfs list "$pool/$dataset" >/dev/null 2>&1; then
          echo "Dataset $pool/$dataset does not exist." >&2
          zfs list -r "$pool" >&2
          exit 1
        fi

        zfs mount "$pool" || true
        zfs mount "$pool/$dataset"
        echo "Imported $pool ($enc). Mounts: ${cfg.poolMountPoint} and ${cfg.mountPoint}."
      '';

      replaceScript = pkgs.writeShellScriptBin "storage-disks-replace" ''
        set -euo pipefail
        pool=${pool}
        keyfile=${keyFile}
        yes=0
        args=()
        for a in "$@"; do
          if [ "$a" = "--yes" ]; then
            yes=1
          else
            args+=("$a")
          fi
        done

        ${loadKeyFn}

        if ! zpool list "$pool" >/dev/null 2>&1; then
          echo "zpool $pool is not imported. Run storage-disks-import first." >&2
          exit 1
        fi

        enc=$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo "off")
        if [ "$enc" != "off" ] && [ "$enc" != "-" ]; then
          status=$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo "unavailable")
          if [ "$status" != "available" ]; then
            load_key "$keyfile"
          fi
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
          echo "This will replace $old with $new in pool $pool." >&2
          echo "The new disk will be resilvered. Re-run with --yes." >&2
          exit 1
        fi

        zpool replace "$pool" "$old" "$new"
        zpool status "$pool"
        echo "Resilver started. Watch with: watch -n 5 zpool status $pool"
      '';

      # Always exits 0. A missing disk or a missing key must not fail the boot job.
      ensureImported = pkgs.writeShellScript "storage-disks-ensure-imported" ''
        set -uo pipefail
        pool=${pool}
        dataset=${dataset}
        keyfile=${keyFile}
        stamp="/run/storage-disks/$pool.missing"

        ${loadKeyFn}

        log() { echo "storage-disks: $*"; }

        if [ -e /run/storage-disks/formatting ]; then
          exit 0
        fi

        imported=0
        if zpool list "$pool" >/dev/null 2>&1; then
          imported=1
        else
          for _ in 1 2 3; do
            if zpool import -f -N -o cachefile=none -d /dev/disk/by-id "$pool"; then
              imported=1
              break
            fi
            sleep 2
          done
        fi

        if [ "$imported" != 1 ]; then
          if [ ! -e "$stamp" ]; then
            mkdir -p /run/storage-disks
            log "$pool is not available. Not mounting it. Boot continues, and import will be retried."
            touch "$stamp"
          fi
          exit 0
        fi

        # Keep this pool out of /etc/zfs/zpool.cache. On NixOS that file is often
        # not writable, and a cached pool is imported early — a missing disk then
        # stalls boot. cachefile=none is not sticky, so set it whenever it drifted.
        cf=$(zpool get -H -o value cachefile "$pool" 2>/dev/null || true)
        if [ -n "$cf" ] && [ "$cf" != "none" ]; then
          zpool set cachefile=none "$pool" >/dev/null 2>&1 || true
        fi

        enc=$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo "off")
        if [ "$enc" != "off" ] && [ "$enc" != "-" ]; then
          status=$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo "unavailable")
          if [ "$status" != "available" ]; then
            if ! load_key "$keyfile"; then
              if [ ! -e "$stamp" ]; then
                mkdir -p /run/storage-disks
                log "$pool is imported but still locked (key $keyfile). Not mounting it. Boot continues."
                touch "$stamp"
              fi
              exit 0
            fi
            log "unlocked $pool"
          fi
        fi

        zfs mount "$pool" >/dev/null 2>&1 || true
        if zfs list "$pool/$dataset" >/dev/null 2>&1; then
          zfs mount "$pool/$dataset" >/dev/null 2>&1 || true
        else
          log "dataset $pool/$dataset does not exist yet. Pool was left imported."
        fi

        if [ -e "$stamp" ]; then
          log "$pool is imported now."
          rm -f "$stamp"
        fi
        exit 0
      '';

      # Before ZFS import. A pool the kernel will not drop can only be
      # erased here, while it is not imported yet.
      wipeEarly = pkgs.writeShellScript "storage-disks-wipe-early" ''
        set -u
        expected=${escapeShellArg formatStamp}
        stamp=/var/lib/storage-disks/format-stamp
        devices=(${devicesShell})
        if [ -f "$stamp" ] && [ "$(tr -d '\n' < "$stamp")" = "$expected" ]; then
          exit 0
        fi
        root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        root_real=$(readlink -f "$root_src" 2>/dev/null || echo "$root_src")
        for d in "''${devices[@]}"; do
          [ -e "$d" ] || continue
          real=$(readlink -f "$d" || echo "$d")
          if [ -n "$root_real" ] && [ "$real" = "$root_real" ]; then
            echo "Refusing to wipe $d: it is the root disk." >&2
            exit 0
          fi
          echo "Clearing labels on $d before ZFS import."
          wipefs -af "$d" || true
          while read -r part; do
            [ -n "$part" ] || continue
            [ "$part" = "$real" ] && continue
            wipefs -af "$part" || true
          done < <(lsblk -lnpo NAME "$real" 2>/dev/null || true)
        done
        exit 0
      '';

      # Started from the Neo service page (and by Activate) when mode=format.
      # A matching stamp means this formatSerial already ran, so Activate is safe.
      formatApply = pkgs.writeShellScript "storage-disks-format-apply" ''
        set -euo pipefail
        pool=${pool}
        layout=${layout}
        encryption=${encryption}
        expected=${escapeShellArg formatStamp}
        stamp=/var/lib/storage-disks/format-stamp
        devices=(${devicesShell})

        if [ -f "$stamp" ] && [ "$(tr -d '\n' < "$stamp")" = "$expected" ]; then
          echo "storage-disks: this format number was already applied."
          exit 0
        fi

        ok=0
        if zpool list "$pool" >/dev/null 2>&1; then
          ok=1
          enc=$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo "off")
          if [ "$encryption" = "none" ]; then
            [ "$enc" = "off" ] || ok=0
          else
            if [ "$enc" = "off" ] || [ "$enc" = "-" ]; then
              ok=0
            fi
          fi
          if [ "$layout" = "mirror" ]; then
            zpool status "$pool" | grep -q 'mirror-' || ok=0
          elif zpool status "$pool" | grep -q 'mirror-'; then
            ok=0
          fi
          for d in "''${devices[@]}"; do
            zpool status -P "$pool" | grep -F -q "$d" || ok=0
          done
        fi
        if [ "$ok" = 1 ]; then
          mkdir -p /var/lib/storage-disks
          printf '%s\n' "$expected" > "$stamp"
          echo "storage-disks: pool already matches. Not wiping."
          exit 0
        fi

        storage-disks-format --yes
      '';

      replaceApply = pkgs.writeShellScript "storage-disks-replace-apply" ''
        set -euo pipefail
        pool=${pool}
        new=${escapeShellArg cfg.replaceWith}
        expected=${escapeShellArg replaceStamp}
        stamp=/var/lib/storage-disks/replace-stamp
        if [ -z "$new" ]; then
          echo "storage-disks: no replacement disk set."
          exit 0
        fi
        if [ -f "$stamp" ] && [ "$(tr -d '\n' < "$stamp")" = "$expected" ]; then
          echo "storage-disks: this replacement was already applied. Clear the field or change the path."
          exit 0
        fi
        if ! zpool list "$pool" >/dev/null 2>&1; then
          storage-disks-import
        fi
        if zpool status -P "$pool" | grep -F -q "$new"; then
          mkdir -p /var/lib/storage-disks
          printf '%s\n' "$expected" > "$stamp"
          echo "storage-disks: $new is already in $pool."
          exit 0
        fi
        storage-disks-replace --yes "$new"
        mkdir -p /var/lib/storage-disks
        printf '%s\n' "$expected" > "$stamp"
      '';
    in {
      config = mkIf cfg.enabled (mkMerge [
        {
          assertions = [
            {
              assertion = cfg.poolName != "" && cfg.dataset != "";
              message = "neo.services.storage-disks: poolName and dataset must be set.";
            }
            {
              assertion = hasPrefix "/" cfg.poolMountPoint && hasPrefix "/" cfg.mountPoint;
              message = "neo.services.storage-disks: mount points must be absolute paths.";
            }
            {
              assertion = cfg.encryption != "keyfile" || cfg.keyFile != "";
              message = "neo.services.storage-disks: encryption=keyfile requires keyFile.";
            }
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

          # Not wantedBy multi-user.target on purpose. A target waits for units it
          # wants, and zpool import of a missing disk must not hold up boot.
          # The timer starts the import shortly after boot, then retries.
          # Sanoid Requires= this unit, so replication imports again just before it runs.
          systemd.services.storage-disks-ensure-imported = {
            description = "Import, unlock, and mount ZFS pool ${cfg.poolName} if its disks are attached";
            after = [
              "local-fs.target"
              "zfs-import.target"
              "systemd-udev-trigger.service"
            ];
            wants = ["zfs-import.target"];
            path = [
              pkgs.zfs
              pkgs.coreutils
              pkgs.gawk
            ];
            unitConfig = {
              # Never escalate a missing backup disk into emergency mode.
              FailureAction = "none";
              SuccessAction = "none";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = false;
              ExecStart = ensureImported;
              TimeoutStartSec = 25;
              TimeoutStopSec = 5;
            };
          };

          systemd.timers.storage-disks-ensure-imported = {
            description = "Import ${cfg.poolName} after boot, and retry if the disks were late";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnBootSec = "10s";
              OnUnitInactiveSec = "90s";
              AccuracySec = "15s";
            };
          };

          services.zfs.autoScrub = {
            enable = cfg.autoScrub.enable;
            interval = cfg.autoScrub.interval;
          };

          environment.systemPackages = [
            importScript
            replaceScript
            formatScript
          ];

          # Oneshot, not RemainAfterExit. Until it has run it stays idle and
          # does not mark the service down. Activate starts it only when armed.
          systemd.services.storage-disks-wipe-early = mkIf (cfg.mode == "format") {
            description = "Wipe ${cfg.poolName} disks before ZFS import";
            wantedBy = ["zfs-import.target"];
            before = [
              "zfs-import-cache.service"
              "zfs-import-scan.service"
              "zfs-import.target"
            ];
            after = ["systemd-udev-settle.service"];
            path = [pkgs.util-linux pkgs.coreutils];
            unitConfig = {
              DefaultDependencies = false;
              FailureAction = "none";
              SuccessAction = "none";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = false;
              ExecStart = wipeEarly;
              TimeoutStartSec = 60;
            };
          };

          systemd.services.storage-disks-format = {
            description = "Format pool ${cfg.poolName} (${cfg.layout}, ${cfg.encryption})";
            wantedBy = optional (cfg.mode == "format") "multi-user.target";
            after = ["local-fs.target" "systemd-udev-trigger.service"];
            path = [
              formatScript
              pkgs.zfs
              pkgs.systemd
              pkgs.psmisc
              pkgs.coreutils
              pkgs.gawk
              pkgs.util-linux
              pkgs.gnugrep
            ];
            unitConfig = {
              FailureAction = "none";
              SuccessAction = "none";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = false;
              ExecStart = formatApply;
              TimeoutStartSec = 90;
            };
          };

          systemd.services.storage-disks-replace = {
            description = "Replace a missing disk in ${cfg.poolName}";
            wantedBy = optional (cfg.replaceWith != "") "multi-user.target";
            after = ["local-fs.target" "storage-disks-ensure-imported.service"];
            path = [
              replaceScript
              importScript
              pkgs.zfs
              pkgs.coreutils
              pkgs.gawk
              pkgs.util-linux
            ];
            unitConfig = {
              FailureAction = "none";
              SuccessAction = "none";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = false;
              ExecStart = replaceApply;
              TimeoutStartSec = 300;
            };
          };
        }
      ]);
    };
}
