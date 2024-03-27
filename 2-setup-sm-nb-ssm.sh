#!/bin/bash

# Creates a new hybrid activation in SSM and reports back the managed instance ID
# If successful, the log line with the instance ID will look like this:
#   Successfully registered the instance with AWS SSM using Managed instance-id: mi-01234567890abcdef

set -e

CURRENT_REGION=$(aws configure get region || echo "$AWS_REGION")

if [ ! -f /tmp/ssm/ssm-setup-cli ]; then
    mkdir -p /tmp/ssm/
    curl https://amazon-ssm-$CURRENT_REGION.s3.$CURRENT_REGION.amazonaws.com/latest/linux_amd64/ssm-setup-cli -o /tmp/ssm/ssm-setup-cli
fi
sudo chmod +x /tmp/ssm/ssm-setup-cli

SSH_SSM_ROLE='service-role/AmazonEC2RunCommandRoleForManagedInstances'

if [ -f /opt/ml/metadata/resource-metadata.json ]; then
  # SageMaker Studio and notebook instances
  RESOURCE_NAME=$(jq --raw-output '.ResourceName' < /opt/ml/metadata/resource-metadata.json)
  RESOURCE_ARN=$(jq --raw-output '.ResourceArn' < /opt/ml/metadata/resource-metadata.json)
else
  # Probably, endpoint
  RESOURCE_NAME=""
  RESOURCE_ARN=""
fi

echo "setup-sm-nb-ssm: Detected SageMaker resource: $RESOURCE_NAME [$RESOURCE_ARN]"

response=$(aws ssm create-activation \
  --description "Activation for Amazon SageMaker Notebook Instance" \
  --iam-role "$SSH_SSM_ROLE" \
  --registration-limit 1 \
  --region "$CURRENT_REGION")

acode=$(echo $response | jq --raw-output '.ActivationCode')
aid=$(echo $response | jq --raw-output '.ActivationId')

sudo /tmp/ssm/ssm-setup-cli -register -activation-id "$aid" -activation-code "$acode" -region "$CURRENT_REGION" -override
