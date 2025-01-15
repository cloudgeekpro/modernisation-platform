#!/bin/bash

set -euo pipefail

export AWS_PAGER=""
regions="eu-west-2"
ROLE_NAME="ModernisationPlatformAccess"
OUTPUT_FILE="common-roles-report.csv"
TEMP_DIR="temp_roles"
COMMON_ROLES_FILE="$TEMP_DIR/common_roles.txt"

# Initialize output file with headers
echo "Role Name,ARN" > $OUTPUT_FILE

# Create temporary directory for role lists
mkdir -p $TEMP_DIR
rm -f $TEMP_DIR/*

# Assume Role Function
getAssumeRoleCfg() {
    account_id=$1
    echo "Assuming role for account: $account_id"

    # Clear credentials
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

    if ! creds=$(aws sts assume-role --role-arn "arn:aws:iam::${account_id}:role/${ROLE_NAME}" --role-session-name "list-iam-roles" --output json 2>/dev/null); then
        echo "Error: Failed to assume role for account $account_id. Skipping..."
        return 1
    fi

    export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

# Main logic
first_account=true
for account_id in $(jq -r '.account_ids | to_entries[] | "\(.value)"' <<< "$ENVIRONMENT_MANAGEMENT"); do
    account_name=$(jq -r ".account_ids | to_entries[] | select(.value==\"$account_id\").key" <<< "$ENVIRONMENT_MANAGEMENT")
    echo "Processing account: $account_name ($account_id)"

    if ! getAssumeRoleCfg "$account_id"; then
        echo "Skipping account: $account_id due to assume role failure."
        continue
    fi

    for region in $regions; do
        echo "Region: $region"

        # List all IAM roles in the account, excluding AWSServiceRoleFor
        roles=$(aws iam list-roles --region "$region" --query "Roles[?!(starts_with(RoleName, 'AWSServiceRoleFor'))].[RoleName,Arn]" --output text)
        echo "$roles" | awk '{print $1}' > "$TEMP_DIR/$account_id.txt"
    done
done

# Find common roles across all accounts
if [[ $(ls $TEMP_DIR | wc -l) -gt 0 ]]; then
    cp "$(ls $TEMP_DIR | head -n 1)" "$COMMON_ROLES_FILE"
    for file in $TEMP_DIR/*.txt; do
        comm -12 <(sort "$COMMON_ROLES_FILE") <(sort "$file") > "${COMMON_ROLES_FILE}.tmp"
        mv "${COMMON_ROLES_FILE}.tmp" "$COMMON_ROLES_FILE"
    done
fi

# Output common roles with ARNs
for role_name in $(cat "$COMMON_ROLES_FILE"); do
    for file in $TEMP_DIR/*.txt; do
        if grep -q "^$role_name " "$file"; then
            arn=$(grep "^$role_name " "$file" | awk '{print $2}')
            echo "$role_name,$arn" >> $OUTPUT_FILE
            break
        fi
    done
done

# Cleanup
rm -rf $TEMP_DIR
echo "Script execution completed. Common roles saved to $OUTPUT_FILE."
