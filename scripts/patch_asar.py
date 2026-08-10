#!/usr/bin/env python3
"""Apply narrowly scoped, size-preserving Granola Linux compatibility patches.

The app's native process must continue to see Linux so Electron selects Linux
libraries and Granola selects its browser/MediaDevices capture path. Only the
renderer-facing product identity and backend platform normalization are made to
look like macOS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterator


class PatchError(RuntimeError):
    """Raised when an upstream bundle is not exactly what this patch expects."""


@dataclass(frozen=True)
class PatchResult:
    path: str
    label: str
    state: str


class AsarArchive:
    """Minimal ASAR reader/editor for same-size, in-place content changes."""

    def __init__(self, path: Path):
        self.path = path
        self.data = bytearray(path.read_bytes())
        if len(self.data) < 16:
            raise PatchError(f"{path} is too small to be an ASAR archive")

        size_pickle_payload = struct.unpack_from("<I", self.data, 0)[0]
        if size_pickle_payload != 4:
            raise PatchError(
                f"unsupported ASAR size pickle ({size_pickle_payload}, expected 4)"
            )

        self.header_size = struct.unpack_from("<I", self.data, 4)[0]
        header_start = 8
        header_end = header_start + self.header_size
        if header_end > len(self.data):
            raise PatchError("ASAR header extends beyond the archive")

        header_pickle = self.data[header_start:header_end]
        if len(header_pickle) < 8:
            raise PatchError("ASAR header pickle is truncated")

        pickle_payload_size = struct.unpack_from("<I", header_pickle, 0)[0]
        json_size = struct.unpack_from("<I", header_pickle, 4)[0]
        if pickle_payload_size + 4 != self.header_size:
            raise PatchError("ASAR header pickle size is inconsistent")
        if 8 + json_size > len(header_pickle):
            raise PatchError("ASAR JSON header is truncated")

        self.json_start = header_start + 8
        self.json_size = json_size
        raw_json = bytes(self.data[self.json_start : self.json_start + json_size])
        try:
            self.header: dict[str, Any] = json.loads(raw_json.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise PatchError(f"cannot decode ASAR JSON header: {exc}") from exc

        # Re-serializing must be byte-identical before we rely on updating the
        # per-file integrity hashes without changing the header's size/layout.
        serialized = self._serialize_header()
        if serialized != raw_json:
            raise PatchError(
                "ASAR header uses an unsupported JSON encoding; refusing to rewrite it"
            )

        self.payload_start = header_end

    def _serialize_header(self) -> bytes:
        return json.dumps(
            self.header, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")

    def _entry(self, archive_path: str) -> dict[str, Any]:
        parts = PurePosixPath(archive_path.lstrip("/")).parts
        node: dict[str, Any] = self.header
        for part in parts:
            files = node.get("files")
            if not isinstance(files, dict) or part not in files:
                raise PatchError(f"ASAR entry not found: {archive_path}")
            child = files[part]
            if not isinstance(child, dict):
                raise PatchError(f"invalid ASAR entry: {archive_path}")
            node = child
        return node

    def _bounds(self, archive_path: str) -> tuple[int, int, dict[str, Any]]:
        entry = self._entry(archive_path)
        if entry.get("unpacked"):
            raise PatchError(f"cannot patch unpacked ASAR entry: {archive_path}")
        try:
            offset = int(entry["offset"])
            size = int(entry["size"])
        except (KeyError, TypeError, ValueError) as exc:
            raise PatchError(f"ASAR entry is not a packed file: {archive_path}") from exc
        start = self.payload_start + offset
        end = start + size
        if start < self.payload_start or end > len(self.data):
            raise PatchError(f"ASAR entry has invalid bounds: {archive_path}")
        return start, end, entry

    def read_file(self, archive_path: str) -> bytes:
        start, end, _ = self._bounds(archive_path)
        return bytes(self.data[start:end])

    def iter_files(self) -> Iterator[str]:
        def walk(node: dict[str, Any], prefix: tuple[str, ...]) -> Iterator[str]:
            files = node.get("files")
            if not isinstance(files, dict):
                return
            for name, child in files.items():
                if not isinstance(child, dict):
                    continue
                current = (*prefix, name)
                if "size" in child:
                    yield "/".join(current)
                if "files" in child:
                    yield from walk(child, current)

        yield from walk(self.header, ())

    def find_packed_files(self, needle: bytes) -> list[str]:
        matches: list[str] = []
        for archive_path in self.iter_files():
            entry = self._entry(archive_path)
            if entry.get("unpacked"):
                continue
            if needle in self.read_file(archive_path):
                matches.append(archive_path)
        return matches

    def patch_exact(
        self,
        archive_path: str,
        old: bytes,
        new: bytes,
        *,
        expected: int,
        label: str,
    ) -> PatchResult:
        if len(new) > len(old):
            raise PatchError(f"replacement is longer than source for {label}")
        replacement = new.ljust(len(old), b" ")
        start, end, entry = self._bounds(archive_path)
        content = bytes(self.data[start:end])
        old_count = content.count(old)
        new_count = content.count(replacement)

        if old_count == expected and new_count == 0:
            patched = content.replace(old, replacement)
            self.data[start:end] = patched
            self._update_integrity(entry, patched)
            return PatchResult(archive_path, label, "patched")
        if old_count == 0 and new_count == expected:
            return PatchResult(archive_path, label, "already-patched")
        raise PatchError(
            f"unexpected marker count for {label} in {archive_path}: "
            f"source={old_count}, replacement={new_count}, expected={expected}"
        )

    @staticmethod
    def _update_integrity(entry: dict[str, Any], content: bytes) -> None:
        integrity = entry.get("integrity")
        if not isinstance(integrity, dict):
            return
        if integrity.get("algorithm") != "SHA256":
            raise PatchError("unsupported ASAR integrity algorithm")
        integrity["hash"] = hashlib.sha256(content).hexdigest()
        block_size = integrity.get("blockSize")
        blocks = integrity.get("blocks")
        if block_size is not None or blocks is not None:
            if not isinstance(block_size, int) or block_size <= 0:
                raise PatchError("invalid ASAR integrity block size")
            integrity["blocks"] = [
                hashlib.sha256(content[index : index + block_size]).hexdigest()
                for index in range(0, len(content), block_size)
            ]

    def flush(self) -> None:
        serialized = self._serialize_header()
        if len(serialized) != self.json_size:
            raise PatchError(
                "ASAR integrity update changed header size; refusing unsafe rewrite"
            )
        self.data[self.json_start : self.json_start + self.json_size] = serialized
        temporary = self.path.with_name(f".{self.path.name}.patched-{os.getpid()}")
        try:
            temporary.write_bytes(self.data)
            temporary.chmod(self.path.stat().st_mode)
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)


def patch_granola(archive: AsarArchive, macos_version: str) -> list[PatchResult]:
    if not re.fullmatch(r"\d{1,2}(?:\.\d{1,2}){1,2}", macos_version):
        raise PatchError(f"invalid macOS version: {macos_version!r}")

    preload = "dist-electron/preload/preload.js"
    main = "dist-electron/main/index.js"
    results = [
        archive.patch_exact(
            preload,
            b"platform:process.platform",
            b"platform:`darwin`",
            expected=1,
            label="renderer platform identity",
        ),
        archive.patch_exact(
            preload,
            b"osVersion:process.getSystemVersion()",
            f"osVersion:`{macos_version}`".encode(),
            expected=1,
            label="renderer OS version identity",
        ),
        archive.patch_exact(
            main,
            b"?`Windows`:process.platform",
            b"?`Windows`:`macOS`",
            expected=1,
            label="backend platform normalization",
        ),
        archive.patch_exact(
            main,
            b"async function u(e){e(await M.systemPreferences.askForMediaAccess(`microphone`))}",
            b"async function u(e){e(!0)}",
            expected=1,
            label="Linux browser microphone permission bridge",
        ),
    ]

    if b"process.platform===`linux`" not in archive.read_file(main):
        raise PatchError(
            "Granola's Linux browser-audio branch is missing; refusing a macOS identity patch"
        )

    capture_marker = (
        b"navigator.mediaDevices.getDisplayMedia({audio:{sampleRate:e},video:!1})"
    )
    permission_marker = (
        b"navigator.mediaDevices.getDisplayMedia({audio:!0,video:!1})"
    )
    capture_files = archive.find_packed_files(capture_marker)
    permission_files = archive.find_packed_files(permission_marker)
    capture_count = (
        archive.read_file(capture_files[0]).count(capture_marker)
        if len(capture_files) == 1
        else 0
    )
    permission_count = (
        archive.read_file(permission_files[0]).count(permission_marker)
        if len(permission_files) == 1
        else 0
    )
    if (
        len(capture_files) != 1
        or len(permission_files) != 1
        or capture_count != 1
        or permission_count != 1
    ):
        raise PatchError(
            "expected exactly one Granola audio-only Linux loopback implementation "
            f"and permission site; found capture={capture_files} ({capture_count}), "
            f"permission={permission_files} ({permission_count})"
        )
    if b"id:`loopbackAllDevices`" not in archive.read_file(main):
        raise PatchError(
            "Granola's Linux all-output-devices loopback handler is missing"
        )

    archive.flush()
    return results


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asar", type=Path, help="path to Granola's app.asar")
    parser.add_argument(
        "--macos-version",
        default="15.5.0",
        help="macOS version exposed to Granola's renderer (default: 15.5.0)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        archive = AsarArchive(args.asar)
        results = patch_granola(archive, args.macos_version)
    except (OSError, PatchError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    for result in results:
        print(f"{result.state}: {result.label} ({result.path})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
