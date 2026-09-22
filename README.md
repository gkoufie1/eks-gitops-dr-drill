# eks-gitops-dr-drill

A GitOps-deployed service on EKS Fargate, backed by Aurora, with a real
disaster-recovery drill: kill the database mid-traffic, restore it, and
measure actual recovery time against a target RTO — not a claimed one.

**Status:** ✅ Done. **DR drill: target RTO 2 minutes, measured 39.032
seconds, MET** — full results in
[`docs/dr-drill-001-results.md`](docs/dr-drill-001-results.md). Datadog was
deliberately not deployed — no account/API key existed for this project,
so the real integration path is documented instead of faked, in
[`ADR 002`](docs/adr/002-datadog-not-deployed.md). Everything is torn
down and independently verified at $0 — see the final cost pass below.

## Why this exists

Most portfolios stop at "I deployed a Kubernetes cluster." This project
tries to answer the harder question an SRE role actually asks: when
something breaks in production, what's your actual recovery time, and can
you show your work? The build order below mirrors real platform-engineering
sequencing — network, then cluster, then GitOps delivery, then the stateful
piece that makes a DR drill meaningful, then observability, then a cost pass.

## A real snag: region

The first `terragrunt apply` failed — not on our code, on AWS's default
account limit of 5 VPCs per region. `us-east-1` was already at 5 (three
leftover VPCs from an earlier course exercise, a `main-vpc`, and the
account's default VPC). Rather than delete anything without checking what
depended on it first, or wait on a quota increase, this project deploys to
**`us-east-2`** instead — the Terraform state bucket stays in `us-east-1`
(already bootstrapped, and a state bucket's region never has to match its
resources' region), only the actual VPC/EKS/NAT move.

## A real snag: CoreDNS stuck Pending

After the cluster and all three Fargate profiles finished applying,
`kubectl get pods -n kube-system` showed both CoreDNS pods `0/1 Pending`,
`PodScheduled: False`, and — the telling detail — **zero scheduling events**.
Not "no node available," just nothing, ever.

**Why:** EKS auto-deploys the CoreDNS addon the moment the cluster control
plane comes up — before Terraform had finished creating the `kube-system`
Fargate profile a few seconds later. Fargate scheduling isn't the normal
kube-scheduler; it's a mutating webhook that only fires at pod *creation*
time. A pod born before its namespace had a matching profile never gets
retried — there's no EC2 fallback for it to land on either, so it just sits
Pending forever with nothing to report.

**Fix:** `kubectl delete pod -n kube-system -l k8s-app=kube-dns` — the
Deployment recreates them, and this time, with the profile already `ACTIVE`,
the webhook claims them correctly. Confirmed `1/1 Running` on real Fargate
nodes (`fargate-ip-10-0-...`) within about a minute, stable across 2+ minutes
of checks.

## Architecture (Phase 1)

```
                         AWS (us-east-2)
                    ┌─────────────────────────────────────┐
                    │  VPC (10.0.0.0/16)                    │
                    │                                        │
  Internet ── IGW ──┤  ┌──────────┐      ┌──────────┐       │
                    │  │  Public  │      │  Public  │       │
                    │  │  Subnet  │      │  Subnet  │       │
                    │  │  AZ-a    │      │  AZ-b    │       │
                    │  └────┬─────┘      └────┬─────┘       │
                    │       │ NAT             │ NAT         │
                    │  ┌────▼─────┐      ┌────▼─────┐       │
                    │  │ Private  │      │ Private  │       │
                    │  │ Subnet   │      │ Subnet   │       │
                    │  │ (Fargate)│      │ (Fargate)│       │
                    │  └──────────┘      └──────────┘       │
                    │                                        │
                    │  EKS control plane (Fargate-only —     │
                    │  no managed node group, see ADR 001)   │
                    └─────────────────────────────────────┘
```

## What's in this repo vs. what isn't

Everything under `terraform/`, `gitops/`, `docs/` is this project's own —
written here, committed here, and it's the actual source of truth for what
the VPC, EKS cluster, and demo app look like. `gitops/argocd/application.yaml`
in particular is the thing that makes GitOps real: it's how Argo CD knows to
watch *this* repo's `gitops/k8s` path at all.

**Argo CD's own installation is deliberately not in here.** It was installed
by running `kubectl apply` straight against Argo CD's official upstream
manifest (`raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`)
— the standard way to install it, maintained by the Argo project itself, the
same pattern any cluster add-on (cert-manager, ingress-nginx, etc.) uses.
Vendoring an upstream tool's own internals into a project repo would mean
manually tracking its upstream releases instead of letting `kubectl apply`
against their URL do that job. What *is* tracked here is the decision to
install it, and everything it's pointed at managing.

## Why Terragrunt, not just Terraform

The `terragrunt.hcl` root config bootstraps its own S3 state bucket and
DynamoDB lock table automatically on first `init` — the bucket name is
derived live from the AWS account ID (`get_aws_account_id()`), so there's
no placeholder bucket name to remember to edit before running. `live/dev/`
holds only what's actually different per environment; everything shared
(backend config, provider config, region) lives once in the root and is
included, not copied.

## Build log

- [x] Terraform modules: VPC (2 AZs, public/private subnets, one NAT per AZ)
- [x] Terraform module: EKS control plane, Fargate-only (profiles for
      `kube-system`, `argocd`, `apps` — see ADR 001 for why no node group)
- [x] Terragrunt wiring: `live/dev/vpc`, `live/dev/eks`, auto-bootstrapped
      remote state
- [x] Deploy Phase 1, verify cluster reachable and CoreDNS actually running
      on Fargate — hit a real CoreDNS-stuck-Pending bug along the way (see
      above), not the one originally anticipated, fixed and verified
- [x] Argo CD installed via its own Fargate profile, GitOps-deploys a demo
      workload into `apps` — all 7 Argo CD components came up `Running` on
      the first try (unlike CoreDNS, their Fargate profile already existed
      before they did); the CoreDNS race from Phase 1 recurred identically
      on this redeploy, confirming it's a deterministic pattern on a
      Fargate-only cluster, not a one-off fluke — same fix applied. Verified
      past "Synced/Healthy" by actually curling the app through a real
      `kubectl port-forward` tunnel: real `HTTP 200`, not just a reported
      status. Argo CD's synced revision matched the exact git commit pushed.
- [x] Aurora PostgreSQL Serverless v2 (0.5-2 ACU) provisioned, IAM database
      auth enabled, demo app (`app/`) wired to it via IRSA — no password in
      a Secret, ever. Three real bugs hit and fixed in this phase alone:
      - `engine_version = "16.6"` doesn't exist for aurora-postgresql (only
        `16.6-limitless` does) — checked real available versions via
        `aws rds describe-db-engine-versions` before picking `16.9`
      - Every GitHub Actions run failed OIDC auth with a generic "Not
        authorized" error — root cause was this repo having GitHub's
        *immutable* OIDC subject claims enabled, which embeds numeric
        owner/repo IDs into the `sub` claim instead of the plain
        `owner/repo` form. Confirmed via `gh api .../actions/oidc/
        customization/sub`, fixed by matching the trust policy to the real
        claim — not by disabling a real security feature
      - The Service's `targetPort` was left at `80` (correct for the
        original `nginxdemos/hello` placeholder) after the image swap to
        the real app, which listens on `8080` — pods were `Running` and
        `Ready`, but nothing could actually reach them until this was caught
      - The master password never touched a human or this project's own
        logs: a short-lived, IRSA-scoped bootstrap pod read it directly
        from Secrets Manager to create the IAM-mapped database user, and
        that bootstrap role was deleted immediately after — least-duration,
        not just least-privilege
      - Verified past "Running" with real reads and writes: `GET /visits`
        returned `{"id":1,...,"total_visits":1}`, then `{"id":2,...,
        "total_visits":2}` on the next call — actual inserts against
        Aurora, not a mocked response
- [x] **DR drill:** added a second Aurora instance (a reader — a failover
      needs somewhere real to promote to) and forced a genuine
      `aws rds failover-db-cluster` during live traffic, not a reboot or a
      simulation. **Target RTO 2 minutes (set before the drill), measured
      39.032 seconds — MET.** ~10.5s of grace before impact, 5 failed
      requests over ~16s of real downtime (clean `503`s from the app's own
      `/readyz` check, not hangs), confirmed-stable after 5 consecutive
      successful checks. Verified the writer/reader roles actually swapped
      via `aws rds describe-db-clusters` — not just trusting the app's own
      recovery signal. Full breakdown, timestamps, and the honest reading
      of what each number means in
      [`docs/dr-drill-001-results.md`](docs/dr-drill-001-results.md).
- [x] Datadog — **deliberately not deployed.** No Datadog account/API key
      existed for this project, and shipping a fabricated or half-wired
      integration would be exactly the overclaim this project has tried
      not to make anywhere else. [`ADR 002`](docs/adr/002-datadog-not-deployed.md)
      documents the real integration path instead: a sidecar per pod (not
      a DaemonSet — Fargate can't run one), a separate AWS-integration tile
      for Aurora's CloudWatch metrics, and the real cost consequence of
      adding a sidecar to every pod's Fargate billing. Honest "designed,
      not built" beats a demo that only looks wired up.
- [x] Final cost pass — see the full breakdown below
- [x] Full teardown, all phases — Aurora (writer + reader), EKS, VPC, and
      the CI/ECR resources all destroyed, in reverse-dependency order
      (Aurora → EKS → VPC, since Aurora depended on both). `terragrunt
      destroy` exit codes alone aren't proof; confirmed independently via
      `aws eks list-clusters`, `describe-db-clusters`, `describe-vpcs`,
      `describe-nat-gateways`, `describe-addresses`, and
      `describe-repositories`, all empty, all tagged
      `Project=eks-gitops-dr-drill`. `us-east-1`'s VPC count unchanged at
      5, confirming the earlier region switch never touched anything there.

**All phases (VPC/EKS, Argo CD, Aurora + a real IAM-authenticated app, the
DR drill, and Datadog's honest non-deployment) are complete.** This project
is done — built across two sessions, real bugs hit and fixed at every
phase, and torn down to $0 both times.

## Final cost — actual, not estimated

Two separate build sessions, each fully torn down before the next began:

| Session | What ran | Duration | Cost |
|---|---|---|---|
| Session 1 (Phase 1 only) | VPC + EKS + CoreDNS | ~1 hr | ~$0.30-0.35 |
| Session 2 (Phases 2-4) | VPC + EKS + Argo CD + Aurora (writer+reader) + demo app + DR drill | ~2.7 hr | ~$0.96 |
| **Total, whole project** | | | **~$1.30** |

| Resource | Rate | Notes |
|---|---|---|
| EKS control plane | $0.10/hr flat | Bills regardless of usage |
| 2× NAT Gateway | ~$0.045/hr each | One per AZ for real HA |
| Aurora Serverless v2 (writer + reader) | ~$0.12/ACU-hr, 0.5 ACU floor each | Reader added specifically for the DR drill, torn down with everything else |
| Fargate (CoreDNS, Argo CD's 7 components, demo app) | Per vCPU/memory-second | ~10 small pods across the session |
| ECR storage | ~$0.10/GB-month | Images deleted before the repo itself was destroyed |

Calculated from AWS's published `us-east-2` rates against real resource
lifetimes, not Cost Explorer (which lags real time by up to 24h — this
project's numbers were needed before that window closed). Every phase's
teardown was independently verified against AWS directly, not just trusted
from a command's exit code — the full session 1 breakdown is above in the
build log for Phase 1's own numbers.

## Repo layout

```
eks-gitops-dr-drill/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, NAT, routing — reusable
│   │   └── eks/          # EKS control plane, OIDC/IRSA, Fargate profiles
│   └── live/
│       └── dev/
│           ├── vpc/      # terragrunt.hcl — VPC inputs for dev
│           └── eks/      # terragrunt.hcl — EKS inputs for dev
├── terragrunt.hcl        # Root: backend bootstrap, provider, shared inputs
├── docs/
│   └── adr/               # Architecture decision records
└── README.md
```

## Deploying (Phase 1)

```bash
# 1. Set your own IP before applying — passed via env var, never committed
export EKS_ALLOWED_CIDR="$(curl -4 -s ifconfig.me)/32"
# a Terraform variable validation hard-fails the apply if this is left at
# 0.0.0.0/0 — see terraform/modules/eks/variables.tf

cd terraform/live/dev/vpc
terragrunt init
terragrunt apply

cd ../eks
terragrunt init
terragrunt apply   # ~10-15 min for the EKS control plane

aws eks update-kubeconfig --name eks-gitops-dr-drill-dev --region us-east-2
kubectl get pods -n kube-system   # verify CoreDNS is Running, not Pending
```

## Teardown

```bash
cd terraform/live/dev/eks && terragrunt destroy
cd ../vpc && terragrunt destroy
```
