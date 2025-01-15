#!/bin/bash

# Set values
export AWS_PAGER=""
regions="eu-west-2"
ROOT_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ROOT_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ROOT_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

ROLE_NAME="ModernisationPlatformAccess"
OUTPUT_FILE="common-roles-report.csv"

## Initialize the output file with headers
echo "Role Name" > $OUTPUT_FILE

# Temporary file to store the intersection of roles
COMMON_ROLES_TEMP="common_roles.txt"
rm -f $COMMON_ROLES_TEMP

# Assume Role Function
getAssumeRoleCfg() {
    account_id=$1
    echo "Assuming role for account: $account_id"
    if ! aws sts assume-role --role-arn "arn:aws:iam::${account_id}:role/${ROLE_NAME}" --role-session-name "list-iam-roles" --output json > credentials.json; then
        echo "Error: Failed to assume role for account $account_id. Skipping..."
        return 1
    fi
    export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' credentials.json)
    export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' credentials.json)
    export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' credentials.json)
}

# Main logic
for account_id in $(jq -r '.account_ids | to_entries[] | "\(.value)"' <<< "$ENVIRONMENT_MANAGEMENT"); do
    account_name=$(jq -r ".account_ids | to_entries[] | select(.value==\"$account_id\").key" <<< "$ENVIRONMENT_MANAGEMENT")
    echo "Processing account: $account_name ($account_id)"
    if ! getAssumeRoleCfg "$account_id"; then
        echo "Skipping account: $account_id due to assume role failure."
        continue
    fi

    for region in $regions; do
        echo "Region: $region"
        AWS_REGION=$region

        # List all IAM roles in the account, excluding AWSServiceRoleFor
        roles=$(aws iam list-roles --region "$region" \
            --query "Roles[?!(starts_with(RoleName, 'AWSServiceRoleFor'))].[RoleName]" \
            --output text)

        echo "Roles found for account $account_id in region $region:"
        echo "$roles"

        # Save roles to a temporary file
        if [[ -n "$roles" ]]; then
            echo "$roles" | sed 's/^ *//;s/ *$//' | sort > "roles_$account_id.txt"
        else
            echo "Warning: No roles found for account $account_id in region $region."
            continue
        fi

        # Update the common roles
        if [[ ! -s $COMMON_ROLES_TEMP ]]; then
            # If common roles file is empty, initialize it with the current account's roles
            mv "roles_$account_id.txt" $COMMON_ROLES_TEMP
        else
            # Intersect the current roles with the existing common roles
            comm -12 $COMMON_ROLES_TEMP "roles_$account_id.txt" > "${COMMON_ROLES_TEMP}.tmp"
            mv "${COMMON_ROLES_TEMP}.tmp" $COMMON_ROLES_TEMP
            rm -f "roles_$account_id.txt"
        fi
    done

    # Reset credentials after each account
    export AWS_ACCESS_KEY_ID=$ROOT_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ROOT_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ROOT_AWS_SESSION_TOKEN
    rm -f credentials.json
done

# Check if there are common roles
if [[ ! -s $COMMON_ROLES_TEMP ]]; then
    echo "Error: No common roles found across accounts."
    exit 1
fi

# Output common roles to CSV
cat $COMMON_ROLES_TEMP >> $OUTPUT_FILE

# Cleanup
rm -f $COMMON_ROLES_TEMP
echo "Script execution completed. Common roles saved to $OUTPUT_FILE."
