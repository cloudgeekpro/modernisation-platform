#!/bin/bash

# Set values
export AWS_PAGER=""
regions="eu-west-2"
ROOT_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ROOT_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ROOT_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

ROLE_NAME="ModernisationPlatformAccess"
OUTPUT_FILE="common-roles-report.csv"

## Initialize workspace mapping
declare -A workspace_map
workspace_map[preproduction]="preprod"
workspace_map[development]="dev"
workspace_map[test]="test"
workspace_map[production]="prod"

# Declare associative arrays
declare -A account_roles
declare -A all_roles

# Initialize the output file with headers
echo -n "Role Name" > $OUTPUT_FILE
for workspace in "${workspace_map[@]}"; do
    echo -n ",$workspace" >> $OUTPUT_FILE
done
echo >> $OUTPUT_FILE

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

# Fetch roles and process
process_roles() {
    account_id=$1
    workspace=$2

    for region in $regions; do
        echo "Fetching roles for account $account_id in region $region..."
        roles=$(aws iam list-roles --region "$region" \
            --query "Roles[?!(starts_with(RoleName, 'AWSServiceRoleFor'))].[RoleName]" \
            --output text | sed 's/^ *//;s/ *$//')

        if [[ -z "$roles" ]]; then
            echo "Warning: No roles found for account $account_id in region $region."
            continue
        fi

        # Add roles to account_roles
        echo "Roles found for account $account_id in workspace $workspace:"
        echo "$roles"
        for role in $roles; do
            account_roles["$workspace,$role"]="Yes"
            all_roles["$role"]=1
        done
    done
}

# Main logic
for account_id in $(jq -r '.account_ids | to_entries[] | "\(.value)"' <<< "$ENVIRONMENT_MANAGEMENT"); do
    account_name=$(jq -r ".account_ids | to_entries[] | select(.value==\"$account_id\").key" <<< "$ENVIRONMENT_MANAGEMENT")
    workspace="unknown"

    # Identify workspace based on account name
    for key in $(printf "%s\n" "${!workspace_map[@]}" | awk '{print length, $0}' | sort -rn | cut -d" " -f2); do
        if [[ "${account_name,,}" == *"${key,,}"* ]]; then
            workspace=${workspace_map[$key]}
            echo "Matched workspace '$workspace' for account name '$account_name' using key '$key'."
            break
        fi
    done

    if [[ "$workspace" == "unknown" ]]; then
        echo "Warning: Could not map account name '$account_name' to a workspace."
    fi

    echo "Processing account: $account_name ($account_id) in workspace: $workspace"
    if ! getAssumeRoleCfg "$account_id"; then
        echo "Skipping account: $account_id due to assume role failure."
        continue
    fi

    # Fetch and process roles for this account
    process_roles "$account_id" "$workspace"

    # Reset credentials after each account
    export AWS_ACCESS_KEY_ID=$ROOT_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ROOT_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ROOT_AWS_SESSION_TOKEN
    rm -f credentials.json
done

# Determine the most common roles
most_common_roles=$(for role in "${!role_counts[@]}"; do
    echo "${role_counts[$role]} $role"
done | sort -nr | head -n 20 | awk '{print $2}')

# Write the most common roles with workspace presence to the output file
for role in $most_common_roles; do
    echo -n "$role" >> $OUTPUT_FILE
    for workspace in "${workspace_map[@]}"; do
        if [[ -n "${account_roles["$workspace,$role"]}" ]]; then
            echo -n ",Yes" >> $OUTPUT_FILE
        else
            echo -n ",No" >> $OUTPUT_FILE
        fi
    done
    echo >> $OUTPUT_FILE
done

echo "Script execution completed. Most common roles saved to $OUTPUT_FILE."
