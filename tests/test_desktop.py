from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).parents[1]
DESKTOP_SCRIPT = PROJECT_DIR / "desktop.sh"


class DesktopIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app_dir = self.root / "Granola build"
        self.app_dir.mkdir()
        runner = self.app_dir / "run-granola"
        runner.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        runner.chmod(0o755)
        (self.app_dir / ".granola-linux-macos-build").write_text(
            "granola_version=test\n", encoding="utf-8"
        )
        (self.app_dir / "granola-app-icon.png").write_bytes(b"test icon")

        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.root / "home")
        self.environment["XDG_DATA_HOME"] = str(self.root / "xdg")
        self.desktop_file = (
            self.root
            / "xdg"
            / "applications"
            / "granola-linux-macos.desktop"
        )

    def run_desktop(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(DESKTOP_SCRIPT), *arguments],
            check=False,
            capture_output=True,
            env=self.environment,
            text=True,
        )

    def test_install_uses_clean_name_and_uninstall_removes_entry(self) -> None:
        installed = self.run_desktop("install", str(self.app_dir))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        contents = self.desktop_file.read_text(encoding="utf-8")

        self.assertIn("\nName=Granola\n", contents)
        self.assertNotIn("Name=Granola (", contents)
        self.assertIn(f'Exec="{self.app_dir}/run-granola" %U\n', contents)
        self.assertIn(f"Icon={self.app_dir}/granola-app-icon.png\n", contents)
        self.assertIn("Categories=Office;\n", contents)
        self.assertIn("StartupNotify=true\n", contents)

        removed = self.run_desktop("uninstall")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.desktop_file.exists())

    def test_rejects_extra_install_arguments(self) -> None:
        result = self.run_desktop("install", str(self.app_dir), "unexpected")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at most one build directory", result.stderr)
        self.assertFalse(self.desktop_file.exists())


if __name__ == "__main__":
    unittest.main()
