#!/usr/bin/env python3
"""Verify a file against an npm-style Subresource Integrity value."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    parser.add_argument("integrity")
    args = parser.parse_args()

    try:
        algorithm, encoded = args.integrity.split("-", 1)
    except ValueError as exc:
        raise SystemExit(f"invalid integrity value: {args.integrity!r}") from exc
    if algorithm not in hashlib.algorithms_available:
        raise SystemExit(f"unsupported integrity algorithm: {algorithm}")

    digest = hashlib.new(algorithm)
    with args.file.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    actual = base64.b64encode(digest.digest()).decode("ascii")
    if not hmac.compare_digest(actual, encoded):
        raise SystemExit(
            f"integrity mismatch for {args.file}: expected {encoded}, got {actual}"
        )
    print(f"integrity OK: {args.file.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
