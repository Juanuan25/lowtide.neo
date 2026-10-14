# Upload the latest snapshot of each backup dataset to S3 Glacier.
# One new object per run. This is not an rclone sync of the mount:
# syncing live files rewrites Glacier objects (early-deletion fees)
# and either misses ZFS snapshots or uploads every snapshot as a full tree.
set -euo pipefail
umask 077

: "${BACKUP_GLACIER_STATE:?}"
: "${BACKUP_GLACIER_DATASETS_FILE:?}"
: "${BACKUP_GLACIER_BUCKET:?}"
: "${BACKUP_GLACIER_REGION:?}"
: "${BACKUP_GLACIER_PREFIX:?}"
: "${BACKUP_GLACIER_STORAGE_CLASS:?}"
: "${BACKUP_GLACIER_PLANNER:?}"
: "${BACKUP_GLACIER_RETENTION_DAYS:?}"
: "${BACKUP_GLACIER_FULL_EVERY_DAYS:?}"
: "${BACKUP_GLACIER_ALLOW_PLAINTEXT:?}"
: "${BACKUP_GLACIER_RECURSIVE:?}"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "backup-glacier: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set by environmentFile" >&2
  exit 1
fi

if ! command -v zfs >/dev/null 2>&1; then
  echo "backup-glacier: zfs is not on PATH (expected the booted system)" >&2
  exit 1
fi

install -d -m 0700 -o root -g root "$BACKUP_GLACIER_STATE"
exec 9>"$BACKUP_GLACIER_STATE/lock"
if ! flock -n 9; then
  echo "backup-glacier: another run holds the lock; leaving it"
  exit 0
fi

state_file="$BACKUP_GLACIER_STATE/state.json"
rclone_config="$BACKUP_GLACIER_STATE/rclone.conf"
: >"$rclone_config"
chmod 0600 "$rclone_config"
now=$(date +%s)
failed=0
sent_or_kept=0
action=""
parent=""
key=""
kind=""
size=""
send_args=()
uploaded_size=""

rclone_base=(
  rclone
  --config "$rclone_config"
  --s3-provider AWS
  --s3-region "$BACKUP_GLACIER_REGION"
  --s3-env-auth
  --s3-storage-class "$BACKUP_GLACIER_STORAGE_CLASS"
  --s3-no-check-bucket
  --s3-server-side-encryption AES256
  --retries 5
  --low-level-retries 10
)
if [ -n "${BACKUP_GLACIER_BWLIMIT:-}" ]; then
  rclone_base+=(--bwlimit "$BACKUP_GLACIER_BWLIMIT")
fi

remote_of() {
  printf ':s3:%s/%s' "$BACKUP_GLACIER_BUCKET" "$1"
}

remote_size() {
  local obj=$1 err out rc parsed errtext
  err=$(mktemp)
  out=$("${rclone_base[@]}" lsjson --stat "$(remote_of "$obj")" 2>"$err") && rc=0 || rc=$?
  if [ "$rc" -eq 3 ]; then
    rm -f "$err"
    printf 'MISSING\n'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    errtext=$(tr '\n' ' ' <"$err")
    rm -f "$err"
    case "$errtext" in
      *[Nn]ot\ found* | *[Dd]oes\ not\ exist* | *directory\ not\ found*)
        printf 'MISSING\n'
        return 0
        ;;
    esac
    echo "backup-glacier: listing $obj failed: $errtext" >&2
    printf 'ERROR\n'
    return 0
  fi
  rm -f "$err"
  if parsed=$(printf '%s' "$out" | python3 -c 'import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(2)
data = json.loads(raw)
if isinstance(data, list):
    if len(data) != 1:
        raise SystemExit(2)
    data = data[0]
if not isinstance(data, dict) or data.get("IsDir") or "Size" not in data:
    raise SystemExit(2)
sys.stdout.write(str(int(data["Size"])))'); then
    printf '%s\n' "$parsed"
    return 0
  fi
  echo "backup-glacier: could not parse the listing for $obj" >&2
  printf 'ERROR\n'
  return 0
}

delete_object() {
  local err rc errtext
  err=$(mktemp)
  "${rclone_base[@]}" deletefile "$(remote_of "$1")" 2>"$err" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$err"
    return 0
  fi
  errtext=$(tr '\n' ' ' <"$err")
  rm -f "$err"
  case "$errtext" in
    *[Nn]ot\ found* | *[Dd]oes\ not\ exist* | *directory\ not\ found*)
      return 0
      ;;
  esac
  echo "backup-glacier: delete $1 failed: $errtext" >&2
  return 1
}

expand_datasets() {
  local root name type listing
  while IFS= read -r root || [ -n "$root" ]; do
    [ -n "$root" ] || continue
    case "$root" in
      -*)
        echo "backup-glacier: refusing dataset name $root" >&2
        return 1
        ;;
    esac
    if ! zfs list -H -o name "$root" >/dev/null 2>&1; then
      echo "backup-glacier: dataset $root is not imported" >&2
      return 1
    fi
    if [ "$BACKUP_GLACIER_RECURSIVE" = "1" ]; then
      if ! listing=$(zfs list -H -o name,type -r "$root"); then
        echo "backup-glacier: could not list children of $root" >&2
        return 1
      fi
      while IFS=$'\t' read -r name type || [ -n "${name:-}" ]; do
        case "$type" in
          filesystem | volume) printf '%s\n' "$name" ;;
        esac
      done <<<"$listing"
    else
      printf '%s\n' "$root"
    fi
  done <"$BACKUP_GLACIER_DATASETS_FILE"
}

latest_snapshot() {
  local out line last=""
  if ! out=$(zfs list -H -t snapshot -o name -s creation "$1" 2>/dev/null); then
    echo "backup-glacier: could not list snapshots of $1" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    last=$line
  done <<<"$out"
  printf '%s\n' "$last"
}

snapshot_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

parse_decide() {
  local line
  action=""
  parent=""
  key=""
  kind=""
  size=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "ACTION "*) action=${line#ACTION } ;;
      "PARENT "*) parent=${line#PARENT } ;;
      "KEY "*) key=${line#KEY } ;;
      "KIND "*) kind=${line#KIND } ;;
      "SIZE "*) size=${line#SIZE } ;;
    esac
  done
}

run_decide() {
  local force=$1 present_flag=$2 dataset=$3 latest_snap=$4 snap_guid=$5 decision
  if ! decision=$(python3 "$BACKUP_GLACIER_PLANNER" decide \
    --state "$state_file" \
    --dataset "$dataset" \
    --latest "$latest_snap" \
    --guid "$snap_guid" \
    --prefix "$BACKUP_GLACIER_PREFIX" \
    --parent-present "$present_flag" \
    --now "$now" \
    --full-every-days "$BACKUP_GLACIER_FULL_EVERY_DAYS" \
    --force "$force"); then
    echo "backup-glacier: planner failed for $dataset" >&2
    return 1
  fi
  parse_decide <<<"$decision"
  if [ -z "$action" ]; then
    echo "backup-glacier: planner returned nothing for $dataset" >&2
    return 1
  fi
}

send_args_for() {
  send_args=()
  if [ "$1" = "1" ]; then
    send_args+=(-w)
  fi
  if [ -n "$2" ]; then
    send_args+=(-i "$2")
  fi
  send_args+=("$3")
}

measure_stream() {
  local out err bytes rc
  err=$(mktemp)
  out=$(zfs send -n -P "${send_args[@]}" 2>"$err") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "backup-glacier: could not measure the stream: $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  bytes=$(printf '%s\n' "$out" | awk '$1 == "size" { print $2; exit }')
  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    echo "backup-glacier: zfs send -n did not report a size" >&2
    return 1
  fi
  if [ "$bytes" -eq 0 ]; then
    echo "backup-glacier: zfs send -n reported an empty stream" >&2
    return 1
  fi
  printf '%s\n' "$bytes"
}

# stdin uploads do not know their length, so rclone will not raise the
# 5 MiB part size. Past 10000 parts the upload dies. S3 also refuses an
# object above 5 TiB. zfs send -n under-reports, so pad the estimate.
chunk_mib() {
  local bytes=$1
  local parts=9500
  local min=8
  local max=560
  local max_object=5497558138880
  local padded need
  if [ "$bytes" -gt "$max_object" ]; then
    echo "backup-glacier: stream estimate is ${bytes} bytes, above S3's 5 TiB object limit" >&2
    return 1
  fi
  padded=$((bytes + bytes / 5))
  if [ "$padded" -lt "$bytes" ] || [ "$padded" -gt "$max_object" ]; then
    padded=$max_object
  fi
  need=$(((padded + parts * 1048576 - 1) / (parts * 1048576)))
  if [ "$need" -lt "$min" ]; then
    need=$min
  fi
  if [ "$need" -gt "$max" ]; then
    echo "backup-glacier: stream needs chunks above ${max}MiB, which this host will not spend on one upload" >&2
    return 1
  fi
  printf '%s\n' "$need"
}

chunk_concurrency() {
  if [ "$1" -ge 256 ]; then
    printf '1\n'
  else
    printf '2\n'
  fi
}

put_stream() {
  local obj=$1 mib=$2 conc=$3 existing
  uploaded_size=""
  existing=$(remote_size "$obj")
  case "$existing" in
    ERROR)
      return 1
      ;;
    MISSING)
      ;;
    0)
      echo "backup-glacier: $obj is an empty object. Removing it." >&2
      delete_object "$obj" || return 1
      ;;
    *)
      if [ -n "$size" ] && [ "$existing" != "$size" ]; then
        echo "backup-glacier: $obj is ${existing} bytes in the bucket and ${size} in state. Not overwriting it." >&2
        return 1
      fi
      echo "backup-glacier: $obj is already in the bucket; not uploading it again"
      uploaded_size=$existing
      return 0
      ;;
  esac

  echo "backup-glacier: uploading $obj ($BACKUP_GLACIER_STORAGE_CLASS, ${mib}MiB parts)"
  if zfs send "${send_args[@]}" | "${rclone_base[@]}" rcat \
    --immutable \
    --s3-chunk-size "${mib}Mi" \
    --s3-upload-concurrency "$conc" \
    --stats 10m \
    "$(remote_of "$obj")"; then
    existing=$(remote_size "$obj")
  else
    existing=$(remote_size "$obj")
    if [ "$existing" = "MISSING" ] || [ "$existing" = "ERROR" ]; then
      echo "backup-glacier: upload of $obj failed" >&2
      return 1
    fi
    echo "backup-glacier: rclone reported failure but $obj is in the bucket" >&2
  fi
  case "$existing" in
    ERROR)
      echo "backup-glacier: upload of $obj finished but it could not be listed. Not recording it." >&2
      return 1
      ;;
    MISSING | 0)
      echo "backup-glacier: upload of $obj did not leave a stream in the bucket" >&2
      delete_object "$obj" || true
      return 1
      ;;
    *)
      uploaded_size=$existing
      return 0
      ;;
  esac
}

record_success() {
  python3 "$BACKUP_GLACIER_PLANNER" record \
    --state "$state_file" \
    --dataset "$1" \
    --key "$2" \
    --kind "$3" \
    --snapshot "$4" \
    --parent "$5" \
    --uploaded "$now" \
    --size "$6"
}

prune_remote() {
  local ds=$1 obj out
  local -a doomed=() dropped=()
  if ! out=$(python3 "$BACKUP_GLACIER_PLANNER" deletes \
    --state "$state_file" \
    --dataset "$ds" \
    --now "$now" \
    --retention-days "$BACKUP_GLACIER_RETENTION_DAYS"); then
    echo "backup-glacier: could not plan deletions for $ds" >&2
    failed=1
    return 0
  fi
  while IFS= read -r obj || [ -n "$obj" ]; do
    case "$obj" in
      "DELETE "*) doomed+=("${obj#DELETE }") ;;
    esac
  done <<<"$out"
  if [ "${#doomed[@]}" -eq 0 ]; then
    return 0
  fi
  for obj in "${doomed[@]}"; do
    echo "backup-glacier: deleting expired $obj"
    if delete_object "$obj"; then
      dropped+=("$obj")
    else
      echo "backup-glacier: could not delete $obj; will retry next run" >&2
      failed=1
    fi
  done
  if [ "${#dropped[@]}" -gt 0 ]; then
    if ! python3 "$BACKUP_GLACIER_PLANNER" drop \
      --state "$state_file" \
      --dataset "$ds" \
      --key "${dropped[@]}"; then
      echo "backup-glacier: deleted objects but could not update state for $ds" >&2
      failed=1
    fi
  fi
}

backup_one() {
  local ds=$1 enc raw=0 latest guid last present=0 bytes mib conc existing
  case "$ds" in
    -*)
      echo "backup-glacier: refusing dataset name $ds" >&2
      return 1
      ;;
  esac
  enc=$(zfs get -H -o value encryption "$ds") || return 1
  if [ "$enc" = "off" ] || [ "$enc" = "-" ]; then
    if [ "$BACKUP_GLACIER_ALLOW_PLAINTEXT" != "1" ]; then
      echo "backup-glacier: $ds is not encrypted. Refusing a plaintext zfs send. Send the replica on the encrypted datadisk, or set allowUnencryptedSend." >&2
      return 1
    fi
    echo "backup-glacier: warning: $ds is plaintext; AWS will store a readable send stream" >&2
    raw=0
  else
    raw=1
  fi

  latest=$(latest_snapshot "$ds") || return 1
  if [ -z "$latest" ]; then
    echo "backup-glacier: $ds has no snapshots; skipping"
    return 0
  fi
  guid=$(zfs get -H -o value guid "$latest") || return 1

  if ! last=$(python3 "$BACKUP_GLACIER_PLANNER" last-snapshot --state "$state_file" --dataset "$ds"); then
    echo "backup-glacier: could not read the last snapshot for $ds" >&2
    return 1
  fi
  present=0
  if [ -n "$last" ] && snapshot_exists "$last"; then
    present=1
  fi

  run_decide auto "$present" "$ds" "$latest" "$guid" || return 1

  if [ "$action" = "incr" ]; then
    send_args_for "$raw" "$parent" "$latest"
    if ! zfs send -n "${send_args[@]}" >/dev/null 2>&1; then
      echo "backup-glacier: $latest is not an incremental child of $parent; sending a full stream"
      run_decide full 0 "$ds" "$latest" "$guid" || return 1
    fi
  fi

  if [ "$action" = "skip" ]; then
    if [ -z "$key" ]; then
      echo "backup-glacier: planner returned no object key for $ds" >&2
      return 1
    fi
    existing=$(remote_size "$key")
    case "$existing" in
      MISSING)
        echo "backup-glacier: state says $latest was uploaded but $key is not in the bucket; sending a full stream"
        run_decide full 0 "$ds" "$latest" "$guid" || return 1
        ;;
      ERROR)
        return 1
        ;;
      0)
        echo "backup-glacier: $key is empty in the bucket. Not treating it as a backup." >&2
        return 1
        ;;
      *)
        if [ -n "$size" ] && [ "$existing" != "$size" ]; then
          echo "backup-glacier: $key is ${existing} bytes in the bucket and ${size} in state. Not overwriting it." >&2
          return 1
        fi
        echo "backup-glacier: $latest is already uploaded"
        sent_or_kept=1
        prune_remote "$ds"
        return 0
        ;;
    esac
  fi

  case "$action" in
    full | incr) ;;
    *)
      echo "backup-glacier: planner returned '$action'" >&2
      return 1
      ;;
  esac
  if [ -z "$key" ] || [ -z "$kind" ]; then
    echo "backup-glacier: planner returned no object key for $ds" >&2
    return 1
  fi

  send_args_for "$raw" "$parent" "$latest"
  echo "backup-glacier: $ds $kind $latest"
  bytes=$(measure_stream) || return 1
  echo "backup-glacier: stream size $(numfmt --to=iec "$bytes" 2>/dev/null || printf '%s bytes' "$bytes") (estimate)"
  mib=$(chunk_mib "$bytes") || return 1
  conc=$(chunk_concurrency "$mib")
  put_stream "$key" "$mib" "$conc" || return 1
  record_success "$ds" "$key" "$kind" "$latest" "$parent" "$uploaded_size" || return 1
  sent_or_kept=1
  prune_remote "$ds"
}

list_file=$(mktemp)
trap 'rm -f "$list_file"' EXIT
if ! expand_datasets >"$list_file"; then
  echo "backup-glacier: could not list datasets" >&2
  exit 1
fi
mapfile -t datasets <"$list_file"

if [ "${#datasets[@]}" -eq 0 ]; then
  echo "backup-glacier: no datasets to send" >&2
  exit 1
fi

declare -A seen=()
unique=()
for ds in "${datasets[@]}"; do
  if [ -z "${seen[$ds]:-}" ]; then
    seen[$ds]=1
    unique+=("$ds")
  fi
done

for ds in "${unique[@]}"; do
  if ! backup_one "$ds"; then
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
if [ "$sent_or_kept" -eq 0 ]; then
  echo "backup-glacier: nothing was uploaded. No dataset had a snapshot." >&2
  exit 1
fi
exit 0
