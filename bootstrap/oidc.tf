locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ──────────────────────────────────────────────
# GitHub Actions OIDC Provider
# ──────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust policy shared by both environment roles. The `sub` condition scopes
# every claim to this repository so no other repo can assume the role.
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ──────────────────────────────────────────────
# Shared deployment policy (state + CI/CD + enough for Terraform apply)
# Resource-scoped to this project's prefix wherever possible.
# ──────────────────────────────────────────────
data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid    = "TerraformStateS3"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket}",
      "arn:aws:s3:::${var.state_bucket}/*",
    ]
  }

  statement {
    sid     = "TerraformStateLock"
    effect  = "Allow"
    actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${var.lock_table}",
    ]
  }

  statement {
    sid    = "ECR"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeRepositories",
      "ecr:BatchDeleteImage",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECSDeployment"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeServices",
      "ecs:DescribeClusters",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RunTask",
      "ecs:StartTask",
      "ecs:StopTask",
      "ecs:DescribeContainerInstances",
      "ecs:ListClusters",
      "ecs:ListServices",
      "ecs:ListTaskDefinitions",
      "ecs:CreateService",
      "ecs:DeleteService",
      "ecs:UpdateCluster",
      "ecs:PutAccountSettingDefault",
      "ecs:PutAccountSetting",
      "ecs:ListTagsForResource",
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassRoleInfra"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/kayaka-*-ecs-*", "arn:aws:iam::${local.account_id}:role/kayaka-*-ecs-execution", "arn:aws:iam::${local.account_id}:role/kayaka-*"]
  }

  statement {
    sid       = "CloudWatchLogs"
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:${var.github_repo}*:*"]
  }

  statement {
    sid    = "PerfInsights"
    effect = "Allow"
    actions = [
      "pi:GetMetrics",
      "pi:DescribeDimensionKeys",
      "pi:GetResourceMetadata",
      "pi:ListAvailableResourceDimensions",
      "pi:ListAvailableResourceMetrics",
    ]
    resources = ["*"]
  }

  # The remaining actions are consumed by `terraform apply` for the
  # resources defined in ../terraform. They are grouped together because
  # AWS does not offer ARN-level scoping for most of these onCreate paths.
  statement {
    sid    = "TerraformManagedResources"
    effect = "Allow"
    actions = [
      "ec2:*",
      "vpc:*",
      "elasticloadbalancing:*",
      "rds:*",
      "secretsmanager:*",
      "kms:*",
      "cloudwatch:*",
      "sns:*",
      "lambda:*",
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:CreatePolicy",
      "iam:GetPolicy",
      "iam:DeletePolicy",
      "iam:CreateInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "ecr:DescribeImages",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_actions_deploy" {
  name        = "kayaka-github-actions-deploy"
  description = "Permissions for GitHub Actions to provision infra and deploy the Kayaka app"
  policy      = data.aws_iam_policy_document.github_actions_deploy.json
}

# ──────────────────────────────────────────────
# Staging / Production roles
# ──────────────────────────────────────────────
resource "aws_iam_role" "staging" {
  name               = "github-actions-staging"
  description        = "Assumed by GitHub Actions to deploy to staging"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role" "production" {
  name               = "github-actions-production"
  description        = "Assumed by GitHub Actions to deploy to production"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy_attachment" "staging" {
  role       = aws_iam_role.staging.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}

resource "aws_iam_role_policy_attachment" "production" {
  role       = aws_iam_role.production.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}

output "staging_role_arn" {
  description = "ARN of the staging GitHub Actions role"
  value       = aws_iam_role.staging.arn
}

output "production_role_arn" {
  description = "ARN of the production GitHub Actions role"
  value       = aws_iam_role.production.arn
}