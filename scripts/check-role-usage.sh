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
echo "Workspace,Role Name,Occurrences" > $OUTPUT_FILE

# Create a temporary directory for role files
mkdir -p $TEMP_DIR
rm -f $TEMP_DIR/*

# Workspace mapping (adjust as needed)
declare -A workspace_map
workspace_map[development]="dev"
workspace_map[test]="test"
workspace_map[preproduction]="preprod"
workspace_map[production]="prod"

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
    workspace="unknown"

    # Identify workspace based on account name (adjust logic as needed)
    for key in "${!workspace_map[@]}"; do
        if [[ "$account_name" == *"$key"* ]]; then
            workspace=${workspace_map[$key]}
            break
        fi
    done

    echo "Processing account: $account_name ($account_id) in workspace: $workspace"
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

        # Save roles to temp directory (include workspace prefix for grouping)
        if [[ -n "$roles" ]]; then
            echo "$roles" | sed 's/^ *//;s/ *$//' | sort > "$TEMP_DIR/$workspace-$account_id.txt"
            echo "Saved roles for $account_id to $TEMP_DIR/$workspace-$account_id.txt"
        else
            echo "Warning: No roles found for account $account_id in region $region."
            touch "$TEMP_DIR/$workspace-$account_id-empty.txt"
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

# Combine all roles from all workspaces into one file
cat $TEMP_DIR/*.txt > "$TEMP_DIR/all_roles.txt"

# Count occurrences of each role
sort "$TEMP_DIR/all_roles.txt" | uniq -c | sort -nr > "$TEMP_DIR/role_counts.txt"

# Save roles with more than 100 occurrences to the output file, grouped by workspace
for workspace in "${workspace_map[@]}"; do
    grep "$workspace" $TEMP_DIR/*.txt | cut -d':' -f2 > "$TEMP_DIR/$workspace-roles.txt"

    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        role=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//;s/ *$//')
        if [[ $count -gt 100 ]]; then
            echo "$workspace,$role,$count" >> "$OUTPUT_FILE"
        fi
    done < "$TEMP_DIR/role_counts.txt"
done

# Cleanup
rm -rf $TEMP_DIR
echo "Script execution completed. Role counts saved to $OUTPUT_FILE."
