# Security policy

## Reporting a problem

Please use GitHub's private security-advisory feature for vulnerabilities in
this builder. Ordinary compatibility failures can use a public issue after
removing account data, meeting content, tokens, cookies, and local paths from
logs.

Vulnerabilities in Granola itself should be reported to Granola through its
official security channel, not published in this repository.

## Trust model

This project is a local repackaging tool. It necessarily executes code from:

- the Granola DMG fetched from Granola's official HTTPS endpoint or supplied by
  the user;
- the exact Linux Electron release identified by that DMG;
- the reviewed npm source packages listed in `locks/npm-sources.json`;
- the host compiler, Node.js, npm, Python, shell, and system libraries.

Electron releases are checked against Electron's official SHA-256 list. The
7-Zip download is pinned by SHA-256, and the reviewed npm package sources are
checked by SHA-512 SRI. The Granola DMG hash is recorded for auditability, but
there is no pinned expected DMG hash because Granola's latest-download endpoint
changes over time. The builder does not validate Apple's code-signing chain.

npm may resolve transitive dependencies of the locked `node-gyp` package on a
first build. npm's registry integrity checks still apply, but those transitive
versions are not fully vendored or reproducibly locked by this project.

## Fail-closed patching

The ASAR patcher requires exact, unique source markers and same-size
replacements. It updates the affected ASAR integrity fields and aborts if the
archive layout, marker count, native Linux branch, or integrity format differs
from what was reviewed. A failed build does not replace a recognized working
output directory.

## Sensitive local state

Generated builds, downloads, DMGs, ASAR files, compiler logs, and caches are
ignored by Git. Granola's runtime profile is outside this repository, normally
at `~/.config/Granola`. It can contain credentials and meeting metadata. Never
attach that directory to an issue or commit it.

The public repository must contain only source tooling. Generated Granola
bundles are proprietary and must not be committed or attached to releases.
