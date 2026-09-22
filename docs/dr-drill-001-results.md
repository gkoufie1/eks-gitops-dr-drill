# DR Drill 001 — Results

**Date:** 2026-09-22
**Target RTO:** 2 minutes
**Result: MET — measured RTO 39.032 seconds**

## What actually happened, in order

| Event | Timestamp (UTC) | Offset from failover |
|---|---|---|
| Steady traffic confirmed (7× consecutive `200` on `/readyz`) | 19:53:20 - 19:53:35 | — |
| **Failover issued** (`aws rds failover-db-cluster`) | **19:53:38.819** | T+0.000s |
| Last successful request before impact | 19:53:49.346 | T+10.527s |
| First failed request (`503`) | 19:53:51.680 | T+12.861s |
| Last failed request | 19:54:03.067 | T+24.248s |
| First successful request after failure | 19:54:07.902 | T+29.083s |
| **Recovery condition met** (5th consecutive `200`) | **19:54:17.851** | **T+39.032s** |

## Reading the numbers honestly

- **~10.5 seconds of grace** between issuing the failover and the first
  failed request — the app kept serving fine briefly while Aurora's
  internal cutover was still in progress. This isn't dead time in the
  measurement; it's a real, useful data point about how much warning a
  client gets before impact.
- **5 failed requests over ~16 seconds** — the actual, real, user-visible
  outage window (`first_fail` → `first_success`). Every one of them
  returned a clean `503` with `{"detail":"database unreachable: ..."}`,
  not a hang or a generic error — the app's `/readyz` design (deliberately
  separated from `/healthz` — see `app/main.py`) surfaced the real failure
  mode cleanly instead of it showing up as an unexplained timeout.
- **~10 seconds between first recovery and the confirmed-stable point** —
  the gap between `first_success` (T+29.083s) and `recovery condition met`
  (T+39.032s) is the 5-consecutive-check buffer from the drill's own
  definition, guarding against reporting a single lucky `200` during a
  flapping window as "recovered." The real service-restored moment is
  closer to T+29s; T+39s is the confirmed-stable number this drill
  committed to measuring before it started.

## Verified against AWS directly, not just the app's own signal

```
Before:  tf-397e6ffbc1bd813dda2c911ff1 = writer, tf-01237a4c20dabe2902ffe771ba = reader
After:   tf-01237a4c20dabe2902ffe771ba = writer, tf-397e6ffbc1bd813dda2c911ff1 = reader
```

`aws rds describe-db-clusters` confirms the writer/reader roles actually
swapped — this was a real Aurora failover promoting the standby, not a
reboot or a simulated failure.

## Why this target was chosen

2 minutes was set *before* the drill ran (see `docs/runbooks/dr-drill.md`),
based on AWS's own documented typical Aurora failover times (well under a
minute in most cases, up to ~2 minutes depending on load). It was a real
target, not calibrated to guarantee a pass after the fact.

## Method

Full procedure in `docs/runbooks/dr-drill.md`. Traffic against `/readyz`
was polled every ~2.3s through a `kubectl port-forward` tunnel throughout
the entire window — before, during, and after the failover — logged with
per-request UTC timestamps to build the table above.
