# Release-candidate recipe, not the build

This directory holds everything needed to rebuild and verify the
`w2g-rc-20260901b-19ce7db` release candidate, minus the 272 MB of compiled
output (870 files of .NET self-contained runtime). The binaries are
deliberately absent: git keeps them forever once committed, and
`RELEASE-CANDIDATE.md` documents a build that needs no context from the
session that produced it.

- `RELEASE-CANDIDATE.md` — the operator's manual: build, verify, install,
  start, stop, locate logs and evidence, roll back.
- `release-manifest.json` — the three version bindings below, plus per-file
  length and SHA-256 for all 860 output files.
- `SHA256SUMS.txt` — the same hashes in `sha256sum -c` form.
- `scripts/`, `inventory/` — the build and inventory tooling that produced it.

| Component | Repository | Ref | Commit |
| --- | --- | --- | --- |
| ControlServer | `8005-agv-control-server` | `ControlServer_MVP` | `19ce7db70893afea6c6361988c3bc612d77569d0` |
| OnboardHmi | `8005-agv-onboard-hmi` | `OnboardHmi_MVP` | `238b46eb2c9a...` |
| Protocol | `8005-agv-protocol` | tag `protocol-v0.1.1` | `1531489e42e3...` |

If you need the built artifact itself rather than a rebuild, attach it to a
GitHub Release instead of committing it here.
