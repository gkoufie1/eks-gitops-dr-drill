data "aws_caller_identity" "current" {}

# ── IAM ROLE FOR EKS CONTROL PLANE ───────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ── EKS CLUSTER ──────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true # scoped down by allowed_cidr_blocks, not left open
    public_access_cidrs     = var.allowed_cidr_blocks
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── OIDC PROVIDER (Required for IRSA) ────────────────────────────
# IRSA = IAM Roles for Service Accounts — lets pods assume scoped IAM
# roles without static credentials. This is what will let the Aurora
# client pod authenticate without a password sitting in a Secret.
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags            = var.tags
}

# ── FARGATE POD EXECUTION ROLE ───────────────────────────────────
# Every Fargate pod runs under this role by default (pulling images,
# writing logs). Per-workload permissions come from IRSA roles on top
# of this, not from widening this role — see the ADR for why Fargate
# was chosen over a managed node group in the first place.
resource "aws_iam_role" "fargate_pod_execution" {
  name = "${var.cluster_name}-fargate-pod-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:fargateprofile/${var.cluster_name}/*"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate_pod_execution.name
}

# ── FARGATE PROFILES ──────────────────────────────────────────────
# This is a Fargate-only cluster — no managed node group at all. Every
# namespace pods actually run in needs its own matching profile, or
# those pods sit Pending forever with no node to schedule onto.

# kube-system: CoreDNS (and anything else EKS bootstraps here) needs
# this or DNS never comes up.
resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "kube-system"
  }

  tags       = var.tags
  depends_on = [aws_eks_cluster.main]
}

# argocd: Argo CD's own control-plane components.
resource "aws_eks_fargate_profile" "argocd" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "argocd"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "argocd"
  }

  tags       = var.tags
  depends_on = [aws_eks_cluster.main]
}

# apps: where Argo CD deploys the demo workload this DR drill targets.
resource "aws_eks_fargate_profile" "apps" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "apps"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "apps"
  }

  tags       = var.tags
  depends_on = [aws_eks_cluster.main]
}
