#!/bin/bash
# lib/aws.sh - AWS EC2 detection and helper functions
#
# Provides AWS EC2 environment detection using IMDSv2.
#
# Usage:
#   source "$(dirname "$0")/../lib/aws.sh"
#   if is_aws_ec2; then
#       echo "Running on AWS EC2"
#   fi
#   TOKEN=$(get_aws_token)

# Retrieve AWS EC2 IMDSv2 token
# Returns: Token string if successful, empty string if not on EC2 or metadata service unavailable
get_aws_token() {
    curl --noproxy "*" -sX PUT "http://169.254.169.254/latest/api/token" \
        --connect-timeout 2 --max-time 5 \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo ""
}

# Check if running on AWS EC2
# Returns: 0 if on EC2, 1 if not
is_aws_ec2() {
    local token
    token=$(get_aws_token)
    [ -n "$token" ]
}

# Get AWS EC2 instance metadata
# Usage: get_aws_metadata "meta-data/instance-id"
get_aws_metadata() {
    local path="$1"
    local token
    
    token=$(get_aws_token)
    if [ -z "$token" ]; then
        return 1
    fi
    
    curl --noproxy "*" -s -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/$path" 2>/dev/null
}

# Get AWS EC2 region
# Usage: REGION=$(get_aws_region)
get_aws_region() {
    get_aws_metadata "meta-data/placement/region"
}

# Get AWS EC2 availability zone
# Usage: AZ=$(get_aws_az)
get_aws_az() {
    get_aws_metadata "meta-data/placement/availability-zone"
}

# Get AWS EC2 instance ID
# Usage: INSTANCE_ID=$(get_aws_instance_id)
get_aws_instance_id() {
    get_aws_metadata "meta-data/instance-id"
}
