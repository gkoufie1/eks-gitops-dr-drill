# Runbook: Tunnel access to in-cluster services

## Why a tunnel at all

Nothing in this cluster is reachable from the public internet by design — pods
run in private subnets (see the VPC module and [ADR 001](../adr/001-fargate-vs-node-groups.md)),
and no LoadBalancer/Ingress has been created for any internal tool. Argo CD's
UI, in particular, should never get a public-facing LoadBalancer just so it's
easy to check — that's real attack surface for a convenience feature.

The safe way in is `kubectl port-forward`: it opens an authenticated tunnel
over the existing EKS API connection (the same one `kubectl get pods` already
uses) straight to a pod or Service, with nothing new exposed to the internet
and no security group or ALB to remember to lock back down afterward. It only
listens on `localhost` on your machine, and it dies the moment you close the
terminal or hit Ctrl+C.

## Prerequisite

```bash
aws eks update-kubeconfig --name eks-gitops-dr-drill-dev --region us-east-2
kubectl get nodes   # confirms kubeconfig is pointed at the right cluster
```

## Tunnel 1 — Argo CD UI

**Status: not usable yet — Argo CD isn't installed (next build phase).** Steps
below are written ahead of time so they're ready the moment it is; the
`argocd` Fargate profile already exists and is waiting for it.

Once Argo CD is installed into the `argocd` namespace:

```bash
# 1. Get the initial admin password (one-time, auto-generated secret)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo   # newline after the password, base64 -d doesn't add one

# 2. Open the tunnel — foreground, holds the terminal
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 3. In a browser
https://localhost:8080
# username: admin
# password: from step 1
# Expect a self-signed cert warning — click through it, this is a local
# tunnel to your own cluster, not a public endpoint that needs a real cert.
```

Leave the `port-forward` command running in its own terminal for as long as
you need the UI open — it doesn't return control until you stop it.

## Tunnel 2 — the demo app

**Status: not usable yet — no app deployed (Argo CD phase deploys it into
`apps`).**

```bash
kubectl port-forward svc/<demo-app-service-name> -n apps 8081:80
# then http://localhost:8081
```

Update `<demo-app-service-name>` once the app's Service name is known from
its k8s manifests.

## Quick verification (once a tunnel is open)

```bash
curl -sk https://localhost:8080/healthz   # Argo CD
curl -s  http://localhost:8081/health     # demo app, once it exists
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `error: unable to forward port because pod is not running` | Target pod isn't `Running` yet | `kubectl get pods -n <namespace>` — wait for `Running`, or diagnose why it isn't (see the CoreDNS incident in the README for the kind of thing that shows up here on a Fargate-only cluster) |
| `connection refused` in the browser/curl, tunnel says it's listening | Wrong local port already in use by something else | Pick a different local port: `8080:443` → `18080:443` |
| Tunnel drops after a few minutes | Normal for a long-idle `port-forward` — the underlying connection isn't infinitely durable | Just re-run the command |
| `Unable to connect to the server: dial tcp ... i/o timeout` | Kubeconfig is stale or pointed at the wrong cluster/region | Re-run the prerequisite `update-kubeconfig` step |

## Cleanup

`Ctrl+C` in the terminal running `port-forward`. Nothing else to clean up —
no LoadBalancer, no security group rule, no DNS record was ever created for
this. That's the point.
