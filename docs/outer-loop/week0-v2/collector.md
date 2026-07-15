# Week 0 v2 Operator Collector

Schema: `outer-loop-week0/v2`

This document is an operator procedure. [policy.md](policy.md) is the sole normative runtime-neutral policy source. If this procedure conflicts with policy, stop; do not reinterpret or weaken policy here.

The collector is an exact, package-covered inline Python 3 program. It installs no helper. The operator extracts the marked source unchanged, verifies its digest against the local passing calibration record, and executes it outside every role boundary.

## Inputs and invocation

The program receives two positional arguments:

1. an existing canonical JSON configuration file;
2. a new output path outside every collected root.

The optional third argument is a prior collector output to compare. The configuration bytes MUST be compact canonical JSON with sorted ASCII keys and one terminal LF. A non-canonical configuration fails before collection.

Run:

```sh
awk '
  /^# BEGIN OUTER_LOOP_WEEK0_V2_COLLECTOR$/ { emit=1 }
  emit { print }
  /^# END OUTER_LOOP_WEEK0_V2_COLLECTOR$/ { exit }
' collector.md > /tmp/week0-v2-collector.py

python3 -m py_compile /tmp/week0-v2-collector.py
python3 - /absolute/config.json /absolute/new-output.json < /tmp/week0-v2-collector.py
python3 - /absolute/config.json /absolute/postflight.json /absolute/preflight.json < /tmp/week0-v2-collector.py
```

A configuration has this shape:

```json
{"collection_id":"opaque-local-id","collector_algorithm_sha256":"sha256:<digest>","mode":"preflight","package_digest":"sha256:<digest>","roots":[{"classification":"reviewable-immutable","content_readable":true,"denied_relative_paths_hex":[],"id":"worktree","lexical_path":"/absolute/path","resolved_path":"/absolute/path","review_symlink_targets":true}],"schema_version":"outer-loop-week0/v2-collector-config"}
```

Allowed `mode` values are `screening`, `preflight`, `postflight`, and `reconciliation`. Allowed root classifications are `reviewable-immutable`, `reviewable-writable`, `declared-disposable`, and `protected-metadata-only`. A denied relative path remains in the safety and enforced-denial inventories but is not traversed; separate current enforcement evidence MUST prove it unreadable to the role.

## Canonical results

The output separates and digest-binds:

- safety metadata;
- review-state content;
- enforced-denial inventory;
- scan completeness and stability;
- collector algorithm/configuration/interpreter/platform identity;
- optional baseline comparison deltas.

Relative path bytes are represented as lowercase hexadecimal. Objects are sorted by root id and path hex. JSON uses sorted ASCII keys, compact separators, and one terminal LF. Any failure exits nonzero, removes a newly created partial output, emits no passing digest, and performs no retry.

## Exact inline source

```python
# BEGIN OUTER_LOOP_WEEK0_V2_COLLECTOR
import hashlib
import json
import os
import platform
import stat
import sys

CONFIG_SCHEMA = "outer-loop-week0/v2-collector-config"
OUTPUT_SCHEMA = "outer-loop-week0/v2-collector-output"
MODES = {"screening", "preflight", "postflight", "reconciliation"}
CLASSES = {
    "reviewable-immutable",
    "reviewable-writable",
    "declared-disposable",
    "protected-metadata-only",
}


class CollectionError(Exception):
    pass


def canonical_bytes(value):
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )


def digest_bytes(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def fail(message):
    raise CollectionError(message)


def require(condition, message):
    if not condition:
        fail(message)


def object_type(mode):
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISLNK(mode):
        return "symlink"
    return "unsupported"


def stable_signature(st):
    return {
        "device": st.st_dev,
        "inode": st.st_ino,
        "mode": stat.S_IMODE(st.st_mode),
        "node_type": object_type(st.st_mode),
        "nlink": st.st_nlink,
        "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns,
    }


def same_object(left, right):
    return stable_signature(left) == stable_signature(right)


def path_hex(relative_path):
    return os.fsencode(relative_path).hex()


def decode_relative_path(encoded):
    require(isinstance(encoded, str), "denied path hex must be a string")
    require(encoded == encoded.lower(), "denied path hex must be lowercase")
    try:
        raw = bytes.fromhex(encoded)
    except ValueError as error:
        raise CollectionError("invalid denied path hex") from error
    relative = os.fsdecode(raw)
    require(relative not in ("", "."), "denied path must not name root")
    require(not os.path.isabs(relative), "denied path must be relative")
    require(".." not in relative.split(os.sep), "denied path must not contain ..")
    require(path_hex(relative) == encoded, "denied path hex is not canonical")
    return relative


def hash_descriptor(fd):
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def safety_record(root, relative, st):
    signature = stable_signature(st)
    signature.update(
        {
            "classification": root["classification"],
            "path_hex": path_hex(relative),
            "root_id": root["id"],
        }
    )
    return signature


def review_record(root, relative, node_type, content_digest=None, target=None):
    record = {
        "classification": root["classification"],
        "node_type": node_type,
        "path_hex": path_hex(relative),
        "root_id": root["id"],
    }
    if content_digest is not None:
        record["content_sha256"] = content_digest
    if target is not None:
        record["symlink_target_hex"] = os.fsencode(target).hex()
    return record


def validate_root(root):
    required = {
        "classification",
        "content_readable",
        "denied_relative_paths_hex",
        "id",
        "lexical_path",
        "resolved_path",
        "review_symlink_targets",
    }
    require(isinstance(root, dict), "root must be an object")
    require(set(root) == required, "root keys do not match schema")
    require(isinstance(root["id"], str) and root["id"], "root id is required")
    require(root["classification"] in CLASSES, "invalid root classification")
    require(type(root["content_readable"]) is bool, "content_readable must be boolean")
    require(
        type(root["review_symlink_targets"]) is bool,
        "review_symlink_targets must be boolean",
    )
    require(
        isinstance(root["denied_relative_paths_hex"], list),
        "denied_relative_paths_hex must be a list",
    )
    require(
        os.path.isabs(root["lexical_path"])
        and os.path.isabs(root["resolved_path"]),
        "root paths must be absolute",
    )
    require(
        os.path.realpath(root["lexical_path"]) == root["resolved_path"],
        "root resolved path mismatch",
    )
    require(
        root["classification"] != "protected-metadata-only"
        or not root["content_readable"],
        "protected metadata root cannot be content readable",
    )
    decoded = [decode_relative_path(item) for item in root["denied_relative_paths_hex"]]
    require(len(decoded) == len(set(decoded)), "duplicate denied relative path")
    require(
        root["denied_relative_paths_hex"]
        == sorted(root["denied_relative_paths_hex"]),
        "denied relative path hex list must be sorted",
    )
    return set(decoded)


def validate_config(config):
    required = {
        "collection_id",
        "collector_algorithm_sha256",
        "mode",
        "package_digest",
        "roots",
        "schema_version",
    }
    require(isinstance(config, dict), "configuration must be an object")
    require(set(config) == required, "configuration keys do not match schema")
    require(config["schema_version"] == CONFIG_SCHEMA, "configuration schema mismatch")
    require(config["mode"] in MODES, "invalid collection mode")
    require(
        isinstance(config["collection_id"], str) and config["collection_id"],
        "collection id is required",
    )
    for field in ("collector_algorithm_sha256", "package_digest"):
        value = config[field]
        require(
            isinstance(value, str)
            and value.startswith("sha256:")
            and len(value) == 71
            and all(character in "0123456789abcdef" for character in value[7:]),
            field + " must be a lowercase sha256 value",
        )
    require(isinstance(config["roots"], list) and config["roots"], "roots are required")
    ids = []
    denied_by_root = {}
    for root in config["roots"]:
        denied_by_root[root["id"]] = validate_root(root)
        ids.append(root["id"])
    require(len(ids) == len(set(ids)), "root ids must be unique")
    require(ids == sorted(ids), "roots must be sorted by id")
    resolved = [root["resolved_path"] for root in config["roots"]]
    for index, left in enumerate(resolved):
        for right in resolved[index + 1 :]:
            try:
                common = os.path.commonpath([left, right])
            except ValueError as error:
                raise CollectionError("root comparison failed") from error
            require(common not in (left, right), "collected roots must not overlap")
    return denied_by_root


def validate_output_location(output_path, roots):
    require(os.path.isabs(output_path), "output path must be absolute")
    require(not os.path.lexists(output_path), "output path already exists")
    output_parent = os.path.realpath(os.path.dirname(output_path))
    require(os.path.isdir(output_parent), "output parent must exist")
    candidate = os.path.join(output_parent, os.path.basename(output_path))
    for root in roots:
        try:
            common = os.path.commonpath([candidate, root["resolved_path"]])
        except ValueError:
            continue
        require(common != root["resolved_path"], "output path is inside collected root")


def scan_root(root, denied):
    lexical = root["lexical_path"]
    first_root_lstat = os.lstat(lexical)
    require(stat.S_ISDIR(first_root_lstat.st_mode), "root is not a directory")
    require(not stat.S_ISLNK(first_root_lstat.st_mode), "root must not be a symlink")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_fd = os.open(lexical, flags)
    safety = []
    review = []
    denied_inventory = []
    try:
        root_fstat = os.fstat(root_fd)
        require(same_object(first_root_lstat, root_fstat), "root changed during open")
        root_device = root_fstat.st_dev
        safety.append(safety_record(root, "", root_fstat))

        def walk(directory_fd, relative_directory):
            entries = list(os.scandir(directory_fd))
            entries.sort(key=lambda entry: os.fsencode(entry.name))
            for entry in entries:
                name = entry.name
                relative = (
                    name
                    if relative_directory == ""
                    else os.path.join(relative_directory, name)
                )
                before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                require(before.st_dev == root_device, "device or mount transition detected")
                node_type = object_type(before.st_mode)
                require(node_type != "unsupported", "unsupported filesystem node")
                safety.append(safety_record(root, relative, before))

                if relative in denied:
                    denied_inventory.append(
                        {
                            "classification": root["classification"],
                            "path_hex": path_hex(relative),
                            "root_id": root["id"],
                        }
                    )
                    continue

                if node_type == "directory":
                    child_fd = os.open(name, flags, dir_fd=directory_fd)
                    try:
                        opened = os.fstat(child_fd)
                        require(same_object(before, opened), "directory changed during open")
                        walk(child_fd, relative)
                        after = os.stat(
                            name,
                            dir_fd=directory_fd,
                            follow_symlinks=False,
                        )
                        require(same_object(before, after), "directory changed during scan")
                    finally:
                        os.close(child_fd)
                elif node_type == "regular":
                    require(before.st_nlink == 1, "multiply linked regular file rejected")
                    if root["content_readable"]:
                        file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                        file_fd = os.open(name, file_flags, dir_fd=directory_fd)
                        try:
                            opened = os.fstat(file_fd)
                            require(same_object(before, opened), "file changed during open")
                            content_digest = hash_descriptor(file_fd)
                            stable = os.fstat(file_fd)
                            require(same_object(opened, stable), "file changed during hash")
                        finally:
                            os.close(file_fd)
                        after = os.stat(
                            name,
                            dir_fd=directory_fd,
                            follow_symlinks=False,
                        )
                        require(same_object(before, after), "file changed after hash")
                        review.append(
                            review_record(
                                root,
                                relative,
                                node_type,
                                content_digest=content_digest,
                            )
                        )
                elif node_type == "symlink":
                    if root["content_readable"] and root["review_symlink_targets"]:
                        target = os.readlink(name, dir_fd=directory_fd)
                        after = os.stat(
                            name,
                            dir_fd=directory_fd,
                            follow_symlinks=False,
                        )
                        require(same_object(before, after), "symlink changed during readlink")
                        review.append(
                            review_record(root, relative, node_type, target=target)
                        )

        walk(root_fd, "")
        final_root_lstat = os.lstat(lexical)
        final_root_fstat = os.fstat(root_fd)
        require(same_object(root_fstat, final_root_fstat), "root changed during scan")
        require(same_object(root_fstat, final_root_lstat), "root path changed during scan")
    finally:
        os.close(root_fd)

    safety.sort(key=lambda item: (item["root_id"], item["path_hex"]))
    review.sort(key=lambda item: (item["root_id"], item["path_hex"]))
    denied_inventory.sort(key=lambda item: (item["root_id"], item["path_hex"]))
    return safety, review, denied_inventory


def scan_all(config, denied_by_root):
    safety = []
    review = []
    denied_inventory = []
    for root in config["roots"]:
        root_safety, root_review, root_denied = scan_root(
            root,
            denied_by_root[root["id"]],
        )
        safety.extend(root_safety)
        review.extend(root_review)
        denied_inventory.extend(root_denied)
    return {
        "denied_inventory": denied_inventory,
        "review_state": review,
        "safety": safety,
    }


def record_map(records):
    return {
        (record["root_id"], record["path_hex"]): record
        for record in records
    }


def delta_records(before, after, category):
    left = record_map(before)
    right = record_map(after)
    deltas = []
    for key in sorted(set(left) | set(right)):
        old = left.get(key)
        new = right.get(key)
        if old == new:
            continue
        if old is None:
            kind = "added"
        elif new is None:
            kind = "removed"
        else:
            kind = "changed"
        deltas.append(
            {
                "after_sha256": None if new is None else digest_bytes(canonical_bytes(new)),
                "before_sha256": None if old is None else digest_bytes(canonical_bytes(old)),
                "category": category,
                "kind": kind,
                "path_hex": key[1],
                "root_id": key[0],
            }
        )
    return deltas


def load_canonical_json(path, label):
    raw = open(path, "rb").read()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CollectionError(label + " is not valid JSON") from error
    require(raw == canonical_bytes(value), label + " is not canonical JSON")
    return value, raw


def main():
    require(len(sys.argv) in (3, 4), "usage: collector CONFIG OUTPUT [BASELINE]")
    config_path = os.path.abspath(sys.argv[1])
    output_path = os.path.abspath(sys.argv[2])
    baseline_path = os.path.abspath(sys.argv[3]) if len(sys.argv) == 4 else None

    config, config_raw = load_canonical_json(config_path, "configuration")
    denied_by_root = validate_config(config)
    validate_output_location(output_path, config["roots"])

    first = scan_all(config, denied_by_root)
    second = scan_all(config, denied_by_root)
    require(
        canonical_bytes(first) == canonical_bytes(second),
        "double inventory or content collection was unstable",
    )
    surface_inventory = [
        {
            "classification": root["classification"],
            "content_readable": root["content_readable"],
            "denied_relative_paths_hex": root["denied_relative_paths_hex"],
            "id": root["id"],
            "lexical_path": root["lexical_path"],
            "resolved_path": root["resolved_path"],
            "review_symlink_targets": root["review_symlink_targets"],
        }
        for root in config["roots"]
    ]
    surface_inventory_digest = digest_bytes(canonical_bytes(surface_inventory))
    denied_inventory_digest = digest_bytes(
        canonical_bytes(second["denied_inventory"])
    )

    identity = {
        "arguments": [config_path, output_path]
        + ([baseline_path] if baseline_path else []),
        "collector_algorithm_sha256": config["collector_algorithm_sha256"],
        "config_sha256": digest_bytes(config_raw),
        "implementation": platform.python_implementation(),
        "mode": config["mode"],
        "platform": platform.platform(),
        "python_executable": os.path.realpath(sys.executable),
        "python_version": platform.python_version(),
    }
    comparison = None
    if baseline_path is not None:
        baseline, _ = load_canonical_json(baseline_path, "baseline")
        require(baseline.get("schema_version") == OUTPUT_SCHEMA, "baseline schema mismatch")
        require(
            baseline.get("package_digest") == config["package_digest"],
            "baseline package mismatch",
        )
        require(
            baseline.get("collector_identity", {}).get("collector_algorithm_sha256")
            == config["collector_algorithm_sha256"],
            "baseline collector algorithm mismatch",
        )
        require(
            baseline.get("task_read_surface_inventory_sha256")
            == surface_inventory_digest,
            "baseline task surface mismatch",
        )
        require(
            baseline.get("enforced_unscanned_denial_inventory_sha256")
            == denied_inventory_digest,
            "baseline enforced denial inventory mismatch",
        )
        deltas = delta_records(
            baseline["manifests"]["safety"],
            second["safety"],
            "safety",
        )
        deltas.extend(
            delta_records(
                baseline["manifests"]["review_state"],
                second["review_state"],
                "review-state",
            )
        )
        deltas.extend(
            delta_records(
                baseline["manifests"]["denied_inventory"],
                second["denied_inventory"],
                "denied-inventory",
            )
        )
        deltas.sort(
            key=lambda item: (
                item["root_id"],
                item["path_hex"],
                item["category"],
            )
        )
        comparison = {
            "baseline_collection_id": baseline["collection_id"],
            "delta_inventory": deltas,
            "delta_inventory_sha256": digest_bytes(canonical_bytes(deltas)),
            "exact_match": len(deltas) == 0,
        }

    output = {
        "collection_id": config["collection_id"],
        "collector_identity": identity,
        "collector_identity_and_config_sha256": digest_bytes(canonical_bytes(identity)),
        "comparison": comparison,
        "manifests": {
            "denied_inventory": second["denied_inventory"],
            "review_state": second["review_state"],
            "safety": second["safety"],
        },
        "mode": config["mode"],
        "package_digest": config["package_digest"],
        "review_state_manifest_sha256": digest_bytes(
            canonical_bytes(second["review_state"])
        ),
        "safety_manifest_sha256": digest_bytes(canonical_bytes(second["safety"])),
        "scan_status": {
            "complete": True,
            "double_inventory_match": True,
            "race_status": "stable",
        },
        "schema_version": OUTPUT_SCHEMA,
        "task_read_surface_inventory_sha256": surface_inventory_digest,
        "enforced_unscanned_denial_inventory_sha256": denied_inventory_digest,
    }
    output_raw = canonical_bytes(output)
    created = False
    try:
        fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created = True
        with os.fdopen(fd, "wb") as stream:
            stream.write(output_raw)
            stream.flush()
            os.fsync(stream.fileno())
        summary = {
            "collection_id": config["collection_id"],
            "output_sha256": digest_bytes(output_raw),
            "review_state_manifest_sha256": output["review_state_manifest_sha256"],
            "safety_manifest_sha256": output["safety_manifest_sha256"],
            "status": "pass",
        }
        sys.stdout.buffer.write(canonical_bytes(summary))
    except Exception:
        if created:
            try:
                os.unlink(output_path)
            except OSError:
                pass
        raise


try:
    main()
except CollectionError as error:
    sys.stderr.buffer.write(
        canonical_bytes(
            {
                "error": str(error),
                "status": "fail-closed",
            }
        )
    )
    sys.exit(2)
except Exception as error:
    sys.stderr.buffer.write(
        canonical_bytes(
            {
                "error": type(error).__name__ + ": " + str(error),
                "status": "fail-closed",
            }
        )
    )
    sys.exit(2)
# END OUTER_LOOP_WEEK0_V2_COLLECTOR
```

## Operator checks

Before each use:

1. Verify the package digest and extract the source exactly once.
2. Verify the extracted source SHA-256 equals the arm's passing `collector_algorithm_sha256`.
3. Create canonical configuration bytes outside every collected root.
4. Confirm every readable surface is present as a scanned root and every omitted subtree has current enforcement-denial evidence.
5. Use a new output path outside every collected root.
6. Retain stdout, stderr, exit status, config digest, output digest, and local immutable provenance.
7. Treat any nonzero exit, absent output, schema mismatch, incomplete channel, or unstable comparison as unavailable evidence. Never repair or retry invisibly.

The collector does not establish role attribution or execution-group quiescence by itself. The operator binds its manifests to the separate provenance, attribution, authority-revocation, quiescence, and hard-link-creation control records defined by [artifact-templates.md](artifact-templates.md).
