export AWS_REGION
export AWS_PROFILE

DB_NAME="$1"
DB_INSTANCE="$2"

usage() {
  echo "Usage: $0 <database-name> <db-instance-identifier> [s3-bucket]"
  echo "  Creates a snapshot + exports it to S3 optional bucket"
  exit 1
}

[ -z "$DB_NAME" ] && usage
[ -z "$DB_INSTANCE" ] && usage

TIMESTAMP=$(date +%Y-%m-%d-%H-%M)
SNAPSHOT_ID="${DB_INSTANCE}-backup-${TIMESTAMP}"

log() {
  echo "[$(date -Iseconds)] $*"
}

log "Creating RDS snapshot: $SNAPSHOT_ID"
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier "$DB_INSTANCE" \
  --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION"

log "Waiting for snapshot to be available..."
aws rds wait db-cluster-snapshot-available \
  --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION"

if [ -n "$3" ]; then
  log "Exporting snapshot to S3 bucket $3..."
  KMS_KEY=$(aws rds describe-db-cluster-snapshots \
    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
    --query "DBClusterSnapshots[0].KmsKeyId" --output text)

  aws rds start-export-task \
    --export-task-identifier "${SNAPSHOT_ID}-export" \
    --source-arn "arn:aws:rds:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster-snapshot:${SNAPSHOT_ID}" \
    --s3-bucket-name "$3" \
    --s3-prefix "backups/${DB_INSTANCE}/${TIMESTAMP}" \
    --kms-key-id "$KMS_KEY"
fi

# Retention: delete snapshots older than 30 days
CUTOFF=$(date -u -d "30 days ago" +%Y-%m-%d)
log "Cleaning up snapshots older than $CUTOFF..."
aws rds describe-db-cluster-snapshots \
  --query "DBClusterSnapshots[?SnapshotCreateTime < '$CUTOFF' && SnapshotType == 'manual'].[DBClusterSnapshotIdentifier]" \
  --output text | while read -r snap; do
    log "Deleting old snapshot: $snap"
    aws rds delete-db-cluster-snapshot \
      --db-cluster-snapshot-identifier "$snap" \
      --region "$AWS_REGION"
  done

log "Backup completed: $SNAPSHOT_ID"