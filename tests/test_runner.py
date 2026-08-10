from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


RUNNER = Path(__file__).parents[1] / "scripts" / "run-granola"
BLUETOOTH_SOURCE = "bluez_input.00:11:22:33:44:55"
BLUETOOTH_CARD = "bluez_card.00_11_22_33_44_55"


class RunnerTests(unittest.TestCase):
    def make_fake_runtime(self, root: Path, default_source: str) -> dict[str, str]:
        fake_bin = root / "bin"
        fake_bin.mkdir()
        state = root / "profile"
        calls = root / "calls"
        state.write_text("a2dp-sink\n")
        calls.write_text("")

        pactl = fake_bin / "pactl"
        pactl.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                case "$1" in
                  get-default-source)
                    printf '%s\n' "$FAKE_DEFAULT_SOURCE"
                    ;;
                  --format=json)
                    printf '[]\n'
                    ;;
                  set-card-profile)
                    printf '%s\n' "$3" >"$FAKE_PROFILE_STATE"
                    printf 'profile %s %s\n' "$2" "$3" >>"$FAKE_CALLS"
                    ;;
                  set-default-source)
                    printf 'source %s\n' "$2" >>"$FAKE_CALLS"
                    ;;
                  *)
                    exit 2
                    ;;
                esac
                """
            )
        )
        pactl.chmod(0o755)

        jq = fake_bin / "jq"
        jq.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                cat >/dev/null
                case "$*" in
                  *active_profile*)
                    cat "$FAKE_PROFILE_STATE"
                    ;;
                  *)
                    printf '%s\n' '{BLUETOOTH_SOURCE}'
                    ;;
                esac
                """
            )
        )
        jq.chmod(0o755)

        electron = root / "electron"
        electron.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                printf 'electron %s\n' "$*" >>"$FAKE_CALLS"
                sleep 0.05
                exit "${FAKE_ELECTRON_EXIT:-0}"
                """
            )
        )
        electron.chmod(0o755)

        runner = root / "run-granola"
        runner.write_bytes(RUNNER.read_bytes())
        runner.chmod(0o755)
        return {
            **os.environ,
            "PATH": f"{fake_bin}:/usr/bin:/bin",
            "FAKE_CALLS": str(calls),
            "FAKE_DEFAULT_SOURCE": default_source,
            "FAKE_ELECTRON_EXIT": "7",
            "FAKE_PROFILE_STATE": str(state),
            "GRANOLA_BLUETOOTH_POLL_SECONDS": "0.01",
        }

    def test_holds_bluetooth_mic_profile_and_restores_stereo(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, BLUETOOTH_SOURCE)

            result = subprocess.run(
                [root / "run-granola", "--test-argument"],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 7)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(
                calls[0], f"profile {BLUETOOTH_CARD} headset-head-unit"
            )
            self.assertEqual(calls[1], f"source {BLUETOOTH_SOURCE}")
            self.assertIn("--test-argument", calls[2])
            self.assertEqual(calls[-1], f"profile {BLUETOOTH_CARD} a2dp-sink")

    def test_leaves_non_bluetooth_default_input_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")

            result = subprocess.run(
                [root / "run-granola"],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 7)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 1)
            self.assertTrue(calls[0].startswith("electron "))


if __name__ == "__main__":
    unittest.main()
