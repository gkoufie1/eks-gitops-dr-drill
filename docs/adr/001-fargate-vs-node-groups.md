# ADR 001: Fargate over managed node groups

## Status
Accepted

## Context
This cluster needed a compute layer for EKS. The two realistic options were
a managed node group (EC2 instances Karpenter/Cluster Autoscaler place pods
onto) or Fargate profiles (AWS runs each pod in its own micro-VM, no node to
manage). This project already has a real EC2-node-group reference to compare
against — `platform-eks`, an earlier scaffold in this same portfolio that
went the node-group route but was never deployed.

## Decision
Run this cluster as Fargate-only: no managed node group at all. Every
namespace pods actually schedule into (`kube-system`, `argocd`, `apps`) gets
its own Fargate profile.

## Reasoning

**For Fargate:**
- No node patching, no AMI upgrades, no node-drain-and-replace runbook —
  removes an entire category of operational toil this project isn't trying
  to demonstrate a second time (the node-lifecycle story already exists
  elsewhere in this portfolio's incident-response lab).
- Per-pod billing (vCPU/memory-seconds actually requested) instead of paying
  for a fixed EC2 instance whether pods are using it or not — for a project
  that's built, drilled, and torn down in one session, this matters more
  than it would for an always-on cluster.
- No shared node blast radius: a compromised or noisy-neighbor pod on a node
  group can affect every other pod scheduled onto that same instance.
  Fargate pods don't share a kernel with anything outside their own task.

**Against Fargate (real tradeoffs, not glossed over):**
- No DaemonSets — a node-level log/metrics agent (the usual way to run
  something like the Datadog Agent) doesn't work on Fargate. This project
  uses Datadog's Fargate-specific sidecar/ECS-style integration instead,
  which is more setup than "install the DaemonSet" would have been.
- No privileged or `hostNetwork` pods — rules out some CNI-level and
  node-debugging tooling outright.
- Slightly higher cost per vCPU-hour than an equivalent EC2 instance at
  steady, predictable, high utilization — the node-group model wins on cost
  once a workload is large and stable enough to bin-pack efficiently across
  a fleet you're keeping busy.

## Consequences
CoreDNS and Argo CD's own components need explicit Fargate profiles or they
sit `Pending` forever — this is documented as a real failure mode in the
build log, not something skipped over. Observability needed a different
Datadog integration path than the default DaemonSet approach. In exchange,
there's no node fleet to patch, size, or drain during the DR drill this
project builds toward.

If this were a steady-state production platform running dozens of services
at predictable, high utilization rather than a focused, torn-down-same-day
build, a managed node group (or Karpenter) would very likely win instead —
that tradeoff, not "Fargate is strictly better," is the actual point of this
ADR.
