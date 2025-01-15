#!/bin/bash

# Set values
export AWS_PAGER=""
regions="eu-west-2"
ROOT_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ROOT_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ROOT_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

ROLE_NAME="ModernisationPlatformAccess"
OUTPUT_FILE="common-roles-report.csv"
TEMP_DIR="temp_roles"
COMMON_ROLES_FILE="$TEMP_DIR/common_roles.txt"

## Initialize the output file with headers
echo "Role Name,ARN,Last Accessed" > $OUTPUT_FILE

# Create temporary directory for role lists
mkdir -p $TEMP_DIR
rm -f $TEMP_DIR/*

## Initialize the output file with headers
echo "Account Name,Account ID,Region,Role Name,ARN" > $OUTPUT_FILE

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

## Main logic
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
        roles=$(aws iam list-roles --region $AWS_REGION --query "Roles[?!(starts_with(RoleName, 'AWSServiceRoleFor'))].[RoleName,Arn]" --output text)
        echo "$roles" | awk '{print $1}' > "$TEMP_DIR/$account_id.txt"
    done

    # Reset credentials after each account
    export AWS_ACCESS_KEY_ID=$ROOT_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ROOT_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ROOT_AWS_SESSION_TOKEN
    rm credentials.json

done

# Find common roles across all accounts
if [[ $(ls $TEMP_DIR | wc -l) -gt 0 ]]; then
    cp "$(ls $TEMP_DIR | head -n 1)" "$COMMON_ROLES_FILE"
    for file in $TEMP_DIR/*.txt; do
        comm -12 <(sort "$COMMON_ROLES_FILE") <(sort "$file") > "${COMMON_ROLES_FILE}.tmp"
        mv "${COMMON_ROLES_FILE}.tmp" "$COMMON_ROLES_FILE"
    done
fi

# Output common roles with ARNs and Last Accessed Dates
for role_name in $(cat "$COMMON_ROLES_FILE"); do
    for file in $TEMP_DIR/*.txt; do
        if grep -q "^$role_name " "$file"; then
            arn=$(grep "^$role_name " "$file" | awk '{print $2}')
            last_accessed=$(aws iam get-role --role-name "$role_name" --query 'Role.RoleLastUsed.LastUsedDate' --output text 2>/dev/null || echo "N/A")
            echo "$role_name,$arn,$last_accessed" >> $OUTPUT_FILE
            break
        fi
    done
done

# Cleanup
rm -rf $TEMP_DIR
echo "Script execution completed. Common roles saved to $OUTPUT_FILE."
