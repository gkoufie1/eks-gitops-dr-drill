# ADR 002: Datadog — designed, not deployed

## Status
Not implemented. Documented here instead of built, deliberately — no
Datadog account/API key existed for this project, and fabricating one or
shipping a half-wired integration would be exactly the kind of overclaim
this whole project has tried not to make elsewhere (see the honesty note
in `cloud-api-workflow` and the corrections made to this portfolio's GitHub
profile earlier). This ADR is the honest version: what it would actually
take, and why it isn't a trivial "add a Helm chart" step on this cluster
specifically.

## The real constraint: no DaemonSet on Fargate

Datadog's default, simplest installation is a DaemonSet — one Agent pod
per node, collecting metrics and logs from everything else on that node.
Fargate has no persistent node to put a DaemonSet on (see ADR 001), so
that default path doesn't apply here at all. This isn't a Datadog
limitation — it's the same Fargate tradeoff already paid for CoreDNS and
Argo CD, showing up again for observability.

## What the real integration requires, in two separate pieces

**1. Cluster/app monitoring — a sidecar, not a DaemonSet.**
On EKS Fargate, the Datadog Agent runs as an additional container inside
each pod that needs monitoring, using Autodiscovery annotations on the app
container so the sidecar knows what to watch. Concretely, for
`gitops/k8s/deployment.yaml`:
- Add a second container (`gcr.io/datadoghq/agent:latest`) to the pod spec
- `DD_API_KEY` sourced from a Kubernetes Secret — never a literal in the
  manifest, matching how the Aurora master password was handled
- Unified service tagging via pod labels (`tags.datadoghq.com/env`,
  `/service`, `/version`) so metrics and logs correlate correctly
- **Real cost consequence, not just a config line:** every pod's resource
  requests grow by whatever the sidecar needs, and Fargate bills by the
  pod's total requested vCPU/memory — the sidecar isn't free compute, it's
  a real line item on every pod running it.

**2. Aurora monitoring — the AWS integration, not the sidecar.**
Aurora is a managed service; you don't run an Agent next to it. Datadog's
AWS integration tile reads CloudWatch metrics via a cross-account IAM role
configured in Datadog's own console — a separate mechanism entirely from
the Kubernetes sidecar above, set up once per AWS account rather than per
workload.

## What a dashboard would have shown

The same signal already captured raw in
[`dr-drill-001-results.md`](../dr-drill-001-results.md) — request success
dropping to zero for ~16 seconds, then recovering. A Datadog dashboard
would visualize that timeline; it wouldn't produce new information the
drill doesn't already have. The alert would fire on the same `/readyz`
failures already logged by hand.

## If this gets built later

1. Sign up for Datadog's trial (datadoghq.com, no card required) — a
   human-only step, same category as the AWS console signup in this
   project's own course material
2. `kubectl create secret generic datadog-api-key --from-literal=api-key=...
   -n apps` — never commit the key
3. Add the sidecar to `gitops/k8s/deployment.yaml`, let Argo CD deploy it
   the same way every other change in this project has gone out
4. Configure the AWS integration tile separately for Aurora's CloudWatch
   metrics
5. Re-run the DR drill (`docs/runbooks/dr-drill.md`) with the dashboard
   live, to get the visual evidence this ADR describes but doesn't have
