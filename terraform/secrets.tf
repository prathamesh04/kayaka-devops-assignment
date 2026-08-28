# ──────────────────────────────────────────────
# Secret Rotation Lambda
# ──────────────────────────────────────────────
data "aws_lambda_layer_version" "secrets_manager" {
  layer_name = "SecretsManagerRDSPostgreSQLRotationSingleUser"
  version    = -1
}

data "archive_file" "rotation" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/src"
  output_path = "${path.module}/lambda/dist/rotate_secret.zip"
}

resource "aws_iam_role" "rotation_lambda" {
  name = "${local.name_prefix}-rotation-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "rotation_lambda" {
  name = "${local.name_prefix}-rotation-lambda-policy"
  role = aws_iam_role.rotation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:UpdateSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}/db/credentials*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.rds.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "secret_rotation" {
  function_name = "${local.name_prefix}-secret-rotation"
  description   = "Rotates RDS PostgreSQL credentials in Secrets Manager"
  runtime       = "python3.12"
  handler       = "rotate_secret.lambda_handler"
  timeout       = 30
  role          = aws_iam_role.rotation_lambda.arn

  filename         = data.archive_file.rotation.output_path
  source_code_hash = data.archive_file.rotation.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.rotation_lambda.id]
  }

  layers = [data.aws_lambda_layer_version.secrets_manager.arn]

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    }
  }

  tags = { Name = "${local.name_prefix}-secret-rotation" }
}
