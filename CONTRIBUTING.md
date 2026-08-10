# Contributing

Compatibility reports and narrowly scoped patches are welcome.

Before opening a pull request:

1. Run `python3 -m unittest discover -s tests -v`.
2. Run `bash -n build.sh desktop.sh`.
3. If changing a bundle marker, test against a legally obtained current Granola
   DMG and explain the old and new marker counts.
4. Keep generated apps, DMGs, ASARs, caches, logs, and all Granola user data out
   of the commit.
5. Do not weaken checksum, ASAR-integrity, or fail-closed behavior merely to make
   a new upstream version pass.

Full-build logs may contain local paths or application telemetry. Redact them
carefully before sharing.
