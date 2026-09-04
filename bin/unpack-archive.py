#!/usr/bin/env python3
"""Unpack a tar.gz into a directory, refusing anything that could write
outside it.

setup.sh used to pipe a downloaded tarball straight into `tar xzf` in the
data directory. A tarball is a list of paths chosen by whoever built it: an
absolute member, a `../` member, or a symlink pointing at ~/.ssh followed by
a member writing "through" it, all land outside the directory the user
thought they were extracting into.

  unpack-archive.py <archive.tar.gz> <destination-dir>

Python's "data" extraction filter enforces exactly these rules — relative
paths only, no absolute or upward links, no devices or setuid bits — and
raises rather than silently skipping. Members are listed first so a refusal
names the offending path.
"""
import sys
import tarfile
from pathlib import PurePosixPath


def unsafe(name: str) -> bool:
    p = PurePosixPath(name)
    return p.is_absolute() or any(part == ".." for part in p.parts)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    archive, dest = argv[1], argv[2]

    try:
        with tarfile.open(archive, "r:gz") as tar:
            members = tar.getmembers()
            for m in members:
                if unsafe(m.name):
                    print(f"unpack: refusing member outside the archive root: {m.name}",
                          file=sys.stderr)
                    return 3
                if m.islnk() or m.issym():
                    if unsafe(m.linkname):
                        print(f"unpack: refusing link escaping the root: "
                              f"{m.name} -> {m.linkname}", file=sys.stderr)
                        return 3
                elif not (m.isfile() or m.isdir()):
                    print(f"unpack: refusing special member: {m.name}", file=sys.stderr)
                    return 3
            # filter="data" re-checks all of the above and additionally drops
            # ownership, setuid/setgid and non-portable modes.
            tar.extractall(path=dest, members=members, filter="data")
    except (tarfile.TarError, OSError) as exc:
        print(f"unpack: {exc}", file=sys.stderr)
        return 1

    print(f"unpacked {len(members)} members into {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
