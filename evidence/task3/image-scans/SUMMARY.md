# Image vulnerability scans (Trivy 0.76.1, HIGH + CRITICAL only)

Run with: `./scripts/scan-images.sh` — full per-image reports are in this folder.

## Before vs after

| Image | Base image before → after | Before (CRIT / HIGH) | After (CRIT / HIGH) | Fixable now |
|---|---|---|---|---|
| frontend | nginx-unprivileged 1.28.0-alpine → 1.30.6-alpine + `apk upgrade` | 3 / 46 | **0 / 0** | 0 |
| backend | python 3.12.11-slim → 3.12.16-slim | 6 / 119 | **0 / 44** | 0 |
| worker | python 3.12.11-slim → 3.12.16-slim | 6 / 119 | **0 / 44** | 0 |
| postgres | postgres 17.6-alpine → 17.11-alpine | 3 / 51 | **1 / 25** | 26 (all in `gosu`) |
| **Total** | | **18 / 335** | **1 / 113** | |

Root cause of the "before" numbers: base images pinned about a year earlier.
Pinning versions (never `latest`) makes builds reproducible, but it also means
images must be **re-scanned and bumped regularly** — that's the trade-off.
In Task 4 the CI pipeline runs this scan on every build.

All findings are in the **operating-system layer**. The Python libraries
(Flask, gunicorn, psycopg, boto3) have **zero** HIGH/CRITICAL findings.

## Remaining findings – accepted risks

**backend / worker (44 HIGH, 0 fixable):** Debian has not yet released patched
packages for these (Trivy shows no "Fixed Version"). Mitigations in place:
non-root user, read-only root filesystem, all Linux capabilities dropped,
no privilege escalation, NetworkPolicies limiting reachability. Action:
rebuild when Debian ships fixes (CI will flag it).

**postgres (1 CRITICAL, 25 HIGH):** all in `/usr/local/bin/gosu`, a helper in
the official image compiled with an old Go version. gosu is only executed when
the container starts as **root** to switch to the postgres user. Our pod runs
as UID 70 from the start (`runAsUser: 70`, `runAsNonRoot: true`), so **gosu
never runs**. Production alternative: managed RDS (no container image to patch).
