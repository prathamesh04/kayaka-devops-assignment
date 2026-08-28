"""
Stub handler for RDS credential rotation.

The actual rotation logic is provided by the AWS-managed layer
`SecretsManagerRDSPostgreSQLRotationSingleUser`, which supplies AWS's
single-user rotation handler (lambda_handler). This function body only
needs to exist so the Lambda can be packaged; the real handler enters
via the layer at runtime via the full module reference.
"""


def lambda_handler(event, context):
    raise NotImplementedError(
        "Rotation logic is provided by the "
        "SecretsManagerRDSPostgreSQLRotationSingleUser layer"
    )