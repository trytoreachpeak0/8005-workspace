# Component repositories

All five are cloned in place under this workspace and tracked on their own
remotes. This repository never contains their content — `setup.ps1` restores
them. Write authority is defined in `CLAUDE.md`; the "Owner" column below is
why, not a second policy.

| Directory | Remote (`github.com/trytoreachpeak0/`) | Working branch | Owner | Agent access |
| --- | --- | --- | --- | --- |
| `8005---AGV` | `8005---AGV` | `main` | mine | writable |
| `8005-agv-control-server` | `8005-agv-control-server` | `ControlServer_MVP` | mine | writable |
| `8005-agv-onboard-hmi` | `8005-agv-onboard-hmi` | `OnboardHmi_MVP` | colleague | read-only |
| `slots-simulator` | `slots-simulator` | `main` | colleague | read-only |
| `8005-agv-protocol` | `8005-agv-protocol` | `main` | shared | writable, notify Kun Wang |

The naming conventions in `file-naming-convention/` govern this workspace root
and the two repositories marked "mine". The other three keep their own habits.
