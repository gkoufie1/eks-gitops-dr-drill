data "aws_caller_identity" "current" {}

# ── SUBNET GROUP ─────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-aurora"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

# ── SECURITY GROUP ────────────────────────────────────────────────
# Scoped to the VPC's own CIDR, not the whole internet — Fargate pods
# don't get individually-assigned security groups without the VPC CNI's
# "security groups for pods" feature, which adds real complexity this
# project doesn't need just to reach one database.
resource "aws_security_group" "aurora" {
  name        = "${var.cluster_name}-aurora"
  description = "Allow Postgres from inside the VPC only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres from the VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# ── AURORA POSTGRES, SERVERLESS V2 ───────────────────────────────
# Scales between min/max ACUs instead of paying for a fixed instance
# size around the clock — min_capacity 0.5 is the smallest Aurora
# Serverless v2 allows, chosen deliberately for a short-lived drill,
# not a production baseline.
resource "aws_rds_cluster" "main" {
  cluster_identifier     = "${var.cluster_name}-aurora"
  engine                 = "aurora-postgresql"
  engine_mode            = "provisioned"
  engine_version         = var.engine_version
  database_name          = var.database_name
  master_username         = var.master_username

  # AWS generates and rotates the master password itself, stored in
  # Secrets Manager — it's never in this code, state file, or console.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  # The app authenticates via IRSA-issued IAM tokens, not this password —
  # see the ADR. The master password exists only for one-time bootstrap
  # (creating the IAM-mapped database user).
  iam_database_authentication_enabled = true

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  storage_encrypted      = true
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true

  tags = var.tags
}

resource "aws_rds_cluster_instance" "main" {
  cluster_identifier = aws_rds_cluster.main.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.main.engine
  engine_version       = aws_rds_cluster.main.engine_version
  tags                 = var.tags
}

# ── IRSA — IAM ROLE FOR THE APP TO CONNECT VIA rds-db:connect ────
resource "aws_iam_role" "app_db_access" {
  name = "${var.cluster_name}-app-db-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:${var.app_namespace}:${var.app_service_account}"
          "${replace(var.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "app_db_connect" {
  name = "rds-iam-connect"
  role = aws_iam_role.app_db_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_rds_cluster.main.cluster_resource_id}/${var.iam_db_username}"
    }]
  })
}

# The one-time database bootstrap role (secretsmanager:GetSecretValue on
# the master password, scoped to nothing else) lived here just long enough
# to create the IAM-mapped database user and the demo table — see the git
# history for the exact resources. Removed deliberately once that job was
# done: least-duration, not just least-privilege. Its own bootstrap pod
# never printed the password it used, even to this project's own logs.
