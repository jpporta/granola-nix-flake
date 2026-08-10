from __future__ import annotations

import hashlib
import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "patch_asar.py"
SPEC = importlib.util.spec_from_file_location("patch_asar", MODULE_PATH)
assert SPEC and SPEC.loader
PATCH_ASAR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PATCH_ASAR
SPEC.loader.exec_module(PATCH_ASAR)


def integrity(content: bytes) -> dict[str, object]:
    block_size = 16
    return {
        "algorithm": "SHA256",
        "hash": hashlib.sha256(content).hexdigest(),
        "blockSize": block_size,
        "blocks": [
            hashlib.sha256(content[index : index + block_size]).hexdigest()
            for index in range(0, len(content), block_size)
        ],
    }


def make_archive(path: Path) -> dict[str, bytes]:
    files = {
        "dist-electron/preload/preload.js": (
            b"bridge={platform:process.platform,"
            b"osVersion:process.getSystemVersion()}"
        ),
        "dist-electron/main/index.js": (
            b"identity=x===`darwin`?`macOS`:x===`win32`?`Windows`:process.platform;"
            b"audio=process.platform===`linux`?`browser`:`native`"
        ),
        "dist-app/assets/primary-test.js": (
            b"capture=navigator.mediaDevices.getDisplayMedia({audio:{sampleRate:e},video:!1});"
            b"permission=navigator.mediaDevices.getDisplayMedia({audio:!0,video:!1})"
        ),
    }
    root: dict[str, object] = {"files": {}}
    offset = 0
    for archive_path, content in files.items():
        node = root
        parts = archive_path.split("/")
        for part in parts[:-1]:
            node = node["files"].setdefault(part, {"files": {}})  # type: ignore[index,union-attr]
        node["files"][parts[-1]] = {  # type: ignore[index]
            "size": len(content),
            "offset": str(offset),
            "integrity": integrity(content),
        }
        offset += len(content)

    header_json = json.dumps(root, separators=(",", ":")).encode()
    json_padding = b"\0" * ((4 - len(header_json) % 4) % 4)
    string_pickle = struct.pack("<I", len(header_json)) + header_json + json_padding
    header_pickle = struct.pack("<I", len(string_pickle)) + string_pickle
    size_pickle = struct.pack("<II", 4, len(header_pickle))
    path.write_bytes(size_pickle + header_pickle + b"".join(files.values()))
    return files


class PatchAsarTests(unittest.TestCase):
    def test_patches_identity_audio_and_integrity_idempotently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "app.asar"
            make_archive(path)

            archive = PATCH_ASAR.AsarArchive(path)
            results = PATCH_ASAR.patch_granola(archive, "15.5.0", True)
            self.assertTrue(all(result.state == "patched" for result in results))

            reopened = PATCH_ASAR.AsarArchive(path)
            preload = reopened.read_file("dist-electron/preload/preload.js")
            main = reopened.read_file("dist-electron/main/index.js")
            primary = reopened.read_file("dist-app/assets/primary-test.js")
            self.assertIn(b"platform:`darwin`", preload)
            self.assertIn(b"osVersion:`15.5.0`", preload)
            self.assertIn(b"?`Windows`:`macOS`", main)
            self.assertIn(b"process.platform===`linux`", main)
            self.assertEqual(primary.count(b"video:!0"), 2)

            for archive_path in reopened.iter_files():
                entry = reopened._entry(archive_path)
                content = reopened.read_file(archive_path)
                self.assertEqual(
                    entry["integrity"]["hash"], hashlib.sha256(content).hexdigest()
                )

            second_results = PATCH_ASAR.patch_granola(reopened, "15.5.0", True)
            self.assertTrue(
                all(result.state == "already-patched" for result in second_results)
            )

    def test_rejects_invalid_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "app.asar"
            make_archive(path)
            archive = PATCH_ASAR.AsarArchive(path)
            with self.assertRaises(PATCH_ASAR.PatchError):
                PATCH_ASAR.patch_granola(archive, "not-a-version", True)


if __name__ == "__main__":
    unittest.main()
