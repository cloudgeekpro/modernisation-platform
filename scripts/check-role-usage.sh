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

## Initialize the output file with headers
echo "Role Name,Account,Last Accessed" > $OUTPUT_FILE

# Create a temporary directory for role files
mkdir -p $TEMP_DIR
rm -f $TEMP_DIR/*

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

        # List all IAM roles in the account
        roles=$(aws iam list-roles --region "$region" --query "Roles[?!(starts_with(RoleName, 'AWSServiceRoleFor'))].[RoleName]" --output text)
        echo "Roles found for account $account_id in region $region:"
        echo "$roles"
        if [[ -n "$roles" ]]; then
            for role_name in $roles; do
                last_accessed=$(aws iam get-role --role-name "$role_name" --query 'Role.RoleLastUsed.LastUsedDate' --output text 2>/dev/null || echo "N/A")
                echo "$role_name,$account_name,$last_accessed" >> "$TEMP_DIR/$account_id.txt"
            done
        else
            echo "Warning: No roles found for account $account_id in region $region."
            touch "$TEMP_DIR/$account_id-empty.txt"
        fi
    done

    # Reset credentials after each account
    export AWS_ACCESS_KEY_ID=$ROOT_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ROOT_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ROOT_AWS_SESSION_TOKEN
    rm -f credentials.json
done

# Check temp files
if [[ -z "$(ls -A $TEMP_DIR | grep -v empty.txt)" ]]; then
    echo "Error: No roles found in any account. Exiting."
    exit 1
fi

# Find common roles across all accounts
valid_files=$(ls $TEMP_DIR/*.txt | grep -v empty.txt)
cp "$(echo $valid_files | cut -d ' ' -f 1)" "$TEMP_DIR/common_roles.txt"

for file in $valid_files; do
    echo "Comparing with file: $file"
    echo "Current common roles:"
    cat "$TEMP_DIR/common_roles.txt"
    comm -12 <(sort -f "$TEMP_DIR/common_roles.txt" | cut -d ',' -f 1) <(sort -f "$file" | cut -d ',' -f 1) > "$TEMP_DIR/common_roles.tmp"
    mv "$TEMP_DIR/common_roles.tmp" "$TEMP_DIR/common_roles.txt"
done

# Ensure common roles file exists
if [[ ! -s "$TEMP_DIR/common_roles.txt" ]]; then
    echo "Error: No common roles found across accounts."
    exit 1
fi

# Output common roles with Account and Last Accessed
while IFS=',' read -r role_name; do
    grep "^$role_name," $TEMP_DIR/*.txt | awk -F',' '{print $1","$2","$3}' >> $OUTPUT_FILE
done < "$TEMP_DIR/common_roles.txt"

# Cleanup
rm -rf $TEMP_DIR
echo "Script execution completed. Common roles saved to $OUTPUT_FILE."
