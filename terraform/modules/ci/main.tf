data "aws_caller_identity" "current" {}

# ── ECR REPOSITORY FOR THE DEMO APP ──────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "${var.cluster_name}-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── GITHUB ACTIONS OIDC ROLE — PUSH TO THIS ONE ECR REPO ONLY ────
# Reuses the account's existing GitHub OIDC provider (token.actions.
# githubusercontent.com) rather than creating a second one - IAM only
# allows one provider per unique URL per account, and it's meant to be
# shared across projects, each with its own narrowly-scoped role like
# this one.
#
# The first apply of this role used the plain "repo:owner/repo:*" sub
# pattern and every workflow run failed with a generic "Not authorized
# to perform sts:AssumeRoleWithWebIdentity." Root cause: this repo has
# GitHub's immutable OIDC subject claims enabled (confirmed via
# `gh api repos/OWNER/REPO/actions/oidc/customization/sub`) - a real
# security feature that embeds stable numeric owner/repo IDs into the
# sub claim so a renamed or transferred repo can't inherit another
# repo's trust. That's a genuine improvement, not something to switch
# off to make the simpler pattern work - var.oidc_sub_claim_prefix
# below is set to the actual, confirmed claim format instead.
resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-github-actions-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "${var.oidc_sub_claim_prefix}:*"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushPullThisRepoOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.app.arn
      }
    ]
  })
}
