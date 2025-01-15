#!/bin/bash

# Set values
export AWS_PAGER=""
regions="eu-west-2"
ROOT_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ROOT_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ROOT_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

ROLE_NAME="ModernisationPlatformAccess"
OUTPUT_FILE="ssm-automation-role-report.csv"

## Initialize the output file with headers
echo "Account Name,Account ID,Region,Role Name,ARN" > $OUTPUT_FILE

# Assume Role Function
getAssumeRoleCfg() {
    account_id=$1
    echo "Assuming role for account: $account_id"
    if ! aws sts assume-role --role-arn "arn:aws:iam::${account_id}:role/${ROLE_NAME}" --role-session-name "list-iam-roles" --output json > credentials.json; then
        echo "Error: Failed to assume role for account $account_id"
        exit 1
    fi
    export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' credentials.json)
    export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' credentials.json)
    export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' credentials.json)
}

# Main logic
for account_id in $(jq -r '.account_ids | to_entries[] | "\(.value)"' <<< "$ENVIRONMENT_MANAGEMENT"); do
    account_name=$(jq -r ".account_ids | to_entries[] | select(.value==\"$account_id\").key" <<< "$ENVIRONMENT_MANAGEMENT")
    echo "Processing account: $account_name ($account_id)"
    getAssumeRoleCfg "$account_id"

    for region in $regions; do
        echo "Region: $region"
        AWS_REGION=$region

        # List all IAM roles in the account
        roles=$(aws iam list-roles --region $AWS_REGION --query "Roles[].[RoleName,Arn]" --output text)
        echo "Debug: IAM roles found in account $account_id, region $region:"
        echo "$roles"

        while IFS=$'\t' read -r role_name role_arn; do
            last_accessed=$(aws iam get-role --role-name "$role_name" --query 'Role.RoleLastUsed.LastUsedDate' --output text 2>/dev/null || echo "N/A")
            echo "$account_name,$account_id,$region,$role_name,$role_arn,$last_accessed" >> $OUTPUT_FILE
        done <<< "$roles"
    done

    # Reset credentials after each account
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    rm -f credentials.json

done

echo "Script execution completed. Roles saved to $OUTPUT_FILE."
