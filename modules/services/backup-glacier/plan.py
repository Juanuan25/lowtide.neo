#!/usr/bin/env python3
# Decide the next ZFS send and which Glacier objects can be deleted.
# Objects are write-once. This never rewrites a key and never drops
# anything still inside the retention window or still required to
# restore the newest kept full.
import argparse
import json
import os
import sys
import tempfile


def load_state(path):
    if not os.path.exists(path):
        return {"datasets": {}}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"backup-glacier: {path} is corrupt ({exc})") from exc
    if not isinstance(data, dict) or not isinstance(data.get("datasets"), dict):
        raise SystemExit(f"backup-glacier: {path} is not a state file")
    return data


def save_state(path, data):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".state-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def objects_of(state, dataset):
    entry = state["datasets"].get(dataset) or {}
    objs = entry.get("objects") or []
    if not isinstance(objs, list):
        raise SystemExit(f"backup-glacier: bad object list for {dataset}")
    for obj in objs:
        if not isinstance(obj, dict):
            raise SystemExit(f"backup-glacier: bad object in state for {dataset}")
        for field in ("key", "kind", "snapshot", "uploaded"):
            if field not in obj:
                raise SystemExit(
                    f"backup-glacier: state for {dataset} is missing {field}"
                )
        if type(obj["uploaded"]) is not int:
            raise SystemExit(f"backup-glacier: bad upload time for {dataset}")
        if "size" in obj and obj["size"] is not None and type(obj["size"]) is not int:
            raise SystemExit(f"backup-glacier: bad object size for {dataset}")
    return objs


def object_key(prefix, dataset, guid, kind):
    safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in dataset)
    return f"{prefix}/{safe}/{guid}.{kind}.zfs"


def emit(lines):
    sys.stdout.write("\n".join(lines) + "\n")


def emit_decision(action, parent, key, kind, size=""):
    emit([
        f"ACTION {action}",
        f"PARENT {parent}",
        f"KEY {key}",
        f"KIND {kind}",
        f"SIZE {size if size is not None else ''}",
    ])


def cmd_decide(args):
    state = load_state(args.state)
    objs = objects_of(state, args.dataset)
    last = max(objs, key=lambda o: o["uploaded"]) if objs else None
    has_full = any(o.get("kind") == "full" for o in objs)
    now = args.now
    full_stale = True
    if has_full:
        newest_full = max(o["uploaded"] for o in objs if o.get("kind") == "full")
        full_stale = (now - newest_full) >= args.full_every_days * 86400

    force_full = args.force == "full"
    if not force_full and last and last.get("snapshot") == args.latest and has_full:
        emit_decision("skip", "", last["key"], "", last.get("size", ""))
        return

    parent_ok = (
        not force_full and args.parent_present == "1" and last is not None
    )
    if parent_ok and has_full and not full_stale:
        key = object_key(args.prefix, args.dataset, args.guid, "incr")
        emit_decision("incr", last["snapshot"], key, "incr")
        return

    key = object_key(args.prefix, args.dataset, args.guid, "full")
    emit_decision("full", "", key, "full")


def keys_to_delete(objs, now, retention_days):
    if not objs:
        return []
    cutoff = now - retention_days * 86400
    fulls = [o for o in objs if o.get("kind") == "full"]
    # No full yet: deleting incrementals would strand the repository.
    if not fulls:
        return []
    older = [o for o in fulls if o["uploaded"] <= cutoff]
    if older:
        base = max(older, key=lambda o: o["uploaded"])
    else:
        base = min(fulls, key=lambda o: o["uploaded"])
    base_time = base["uploaded"]
    doomed = []
    for obj in objs:
        if obj["uploaded"] >= base_time:
            continue
        if obj["uploaded"] > cutoff:
            continue
        doomed.append(obj["key"])
    return doomed


def cmd_deletes(args):
    state = load_state(args.state)
    objs = objects_of(state, args.dataset)
    keys = keys_to_delete(objs, args.now, args.retention_days)
    if keys:
        emit([f"DELETE {key}" for key in keys])


def cmd_record(args):
    state = load_state(args.state)
    datasets = state.setdefault("datasets", {})
    entry = datasets.setdefault(args.dataset, {"objects": []})
    objs = entry.setdefault("objects", [])
    if any(o.get("key") == args.key for o in objs):
        save_state(args.state, state)
        return
    if args.size < 1:
        raise SystemExit("backup-glacier: refusing to record an empty object")
    objs.append({
        "key": args.key,
        "kind": args.kind,
        "snapshot": args.snapshot,
        "parent": args.parent or None,
        "uploaded": args.uploaded,
        "size": args.size,
    })
    save_state(args.state, state)


def cmd_drop(args):
    state = load_state(args.state)
    entry = state["datasets"].get(args.dataset)
    if not entry:
        return
    drop = set(args.key)
    entry["objects"] = [o for o in entry.get("objects", []) if o.get("key") not in drop]
    save_state(args.state, state)


def cmd_last_snapshot(args):
    state = load_state(args.state)
    objs = objects_of(state, args.dataset)
    if not objs:
        return
    last = max(objs, key=lambda o: o["uploaded"])
    snap = last.get("snapshot") or ""
    if snap:
        sys.stdout.write(snap + "\n")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(p):
        p.add_argument("--state", required=True)
        p.add_argument("--dataset", required=True)

    decide = sub.add_parser("decide")
    add_common(decide)
    decide.add_argument("--latest", required=True)
    decide.add_argument("--guid", required=True)
    decide.add_argument("--prefix", required=True)
    decide.add_argument("--parent-present", required=True, choices=["0", "1"])
    decide.add_argument("--now", type=int, required=True)
    decide.add_argument("--full-every-days", type=int, required=True)
    decide.add_argument("--force", choices=["auto", "full"], default="auto")
    decide.set_defaults(func=cmd_decide)

    deletes = sub.add_parser("deletes")
    add_common(deletes)
    deletes.add_argument("--now", type=int, required=True)
    deletes.add_argument("--retention-days", type=int, required=True)
    deletes.set_defaults(func=cmd_deletes)

    record = sub.add_parser("record")
    add_common(record)
    record.add_argument("--key", required=True)
    record.add_argument("--kind", required=True, choices=["full", "incr"])
    record.add_argument("--snapshot", required=True)
    record.add_argument("--parent", default="")
    record.add_argument("--uploaded", type=int, required=True)
    record.add_argument("--size", type=int, required=True)
    record.set_defaults(func=cmd_record)

    drop = sub.add_parser("drop")
    add_common(drop)
    drop.add_argument("--key", action="append", required=True)
    drop.set_defaults(func=cmd_drop)

    last = sub.add_parser("last-snapshot")
    add_common(last)
    last.set_defaults(func=cmd_last_snapshot)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
