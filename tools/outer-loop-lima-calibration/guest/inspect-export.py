#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


SECRET_NAME = re.compile(r"(^|/)(\.env($|\.)|id_(rsa|ed25519)|.*\.(key|pem|p12)$|\.credentials\.json$)", re.IGNORECASE)


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    records: list[dict[str, object]] = []
    hazard = False
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        for name in sorted((*names, *files)):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISREG(info.st_mode):
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    digest = hashlib.sha256()
                    while chunk := os.read(descriptor, 1024 * 1024):
                        digest.update(chunk)
                finally:
                    os.close(descriptor)
                node_type = "file"
                file_digest: str | None = digest.hexdigest()
            elif stat.S_ISDIR(info.st_mode):
                node_type, file_digest = "directory", None
            elif stat.S_ISLNK(info.st_mode):
                node_type, file_digest, hazard = "symlink", None, True
            else:
                node_type, file_digest, hazard = "special", None, True
            if SECRET_NAME.search(relative) or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1):
                hazard = True
            records.append({
                "path": relative,
                "type": node_type,
                "mode": f"{stat.S_IMODE(info.st_mode):04o}",
                "nlink": info.st_nlink,
                "sha256": file_digest,
            })
    print(json.dumps({"schema_version": 1, "hazard": hazard, "inventory": records}, sort_keys=True, separators=(",", ":")))
    return 1 if hazard else 0


if __name__ == "__main__":
    sys.exit(main())
