# Runbook: the DR drill

## Objective

Force-fail Aurora's writer during live traffic against the real app, then
measure actual recovery time — not a claimed one.

## Definitions, set before the drill runs (not after)

- **Target RTO: 2 minutes.** AWS documents typical Aurora failover
  completing well under a minute in most cases, up to ~2 minutes depending
  on load and connection draining — 2 minutes is a real target, not a
  softball.
- **Start event:** the timestamp `aws rds failover-db-cluster` is issued.
- **Recovery condition:** 5 consecutive successful `GET /readyz` requests
  (HTTP 200, `{"status":"ready"}`), polled at ~2s intervals. One lucky
  200 during a flapping window doesn't count — five in a row does.
- **Result is published as measured**, met or missed. A missed target with
  a documented cause (DNS caching, connection pool reuse, health-check
  threshold) is worth more here than a suspiciously clean number.

## Procedure

1. Confirm the cluster has 2 instances (writer + reader) — a failover needs
   somewhere to fail over to:
   ```bash
   aws rds describe-db-clusters --db-cluster-identifier eks-gitops-dr-drill-dev-aurora \
     --region us-east-2 --query "DBClusters[0].DBClusterMembers"
   ```
2. Start continuous traffic against `/readyz` through a `kubectl
   port-forward` tunnel (see `tunnel-access.md`), logging each request's
   timestamp and HTTP status to a file — this is what gets analyzed
   afterward to find the actual failure and recovery instants.
3. Once traffic is confirmed steady (several consecutive 200s), issue the
   failover:
   ```bash
   aws rds failover-db-cluster \
     --db-cluster-identifier eks-gitops-dr-drill-dev-aurora \
     --region us-east-2
   ```
4. Let the traffic loop keep running through the outage and recovery —
   don't stop it early. Aurora failover involves a DNS endpoint cutover;
   in-flight connections may take a moment to notice even after the new
   writer is ready, and that lag is part of what's being measured, not
   noise to filter out.
5. Stop the loop once the recovery condition (5 consecutive 200s) is met.
6. From the log: find the timestamp of the last success before failures
   start, and the timestamp of the first success in the final run of 5.
   The gap between them is the measured RTO.

## What "fail" looks like in the log

Expect `/readyz` to return `503` (the app's own honest signal that it
couldn't reach Aurora — see `app/main.py`), not a hung connection or a
generic error — the readiness probe was deliberately built to surface this
clearly rather than let a symptom show up as an unexplained timeout.

## After the drill

- Record the measured RTO against the 2-minute target in the README, met
  or missed, with a cause if missed.
- Tear down the reader instance (or the whole stack, if this is the last
  phase for the session) — it was added specifically for this drill, not
  as a permanent HA posture beyond it.
