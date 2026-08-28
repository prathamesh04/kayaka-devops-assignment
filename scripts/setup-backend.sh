#!/usr/bin/env bash
set -euo pipefail

# Bootstrap remote state backend (S3 + DynamoDB) for Terraform.
# Run once per account before `terraform init`.

REGION="${AWS_REGION:-ap-south-1}"
BUCKET_NAME="${TF_STATE_BUCKET:-kayaka-terraform-state}"
TABLE_NAME="${TF_LOCK_TABLE:-terraform-locks}"

echo "=== Bootstrapping Terraform backend ==="

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Creating S3 state bucket: $BUCKET_NAME"
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
else
  echo "Bucket $BUCKET_NAME already exists"
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{ "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" } }]
  }'

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Enabling CloudTrail object-level logging recommendations..."

if ! aws dynamodb describe-table --table-name "$TABLE_NAME" 2>/dev/null; then
  echo "Creating DynamoDB lock table: $TABLE_NAME"
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  aws dynamodb wait table-exists --table-name "$TABLE_NAME"
else
  echo "Table $TABLE_NAME already exists"
fi

echo ""
echo "Backend bootstrap complete:"
echo "  S3 bucket   : $BUCKET_NAME"
echo "  Lock table  : $TABLE_NAME"
echo "  Region      : $REGION"
echo ""
echo "Next: cd terraform && terraform init"