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


# Function to assume role and set temporary credentials
assume_role() {
    local account_id=$1
    echo "Assuming role for account: $account_id"
    creds=$(aws sts assume-role --role-arn "arn:aws:iam::${account_id}:role/${ROLE_NAME}" --role-session-name "list-iam-roles" --output json || { 
        echo "Error: Failed to assume role for account $account_id. Skipping..."; 
        return 1; 
    })
    export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

# Main logic
accounts=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].[Id,Name]" --output json)

for account in $(echo "$accounts" | jq -c '.[]'); do
    account_id=$(echo "$account" | jq -r '.[0]')
    account_name=$(echo "$account" | jq -r '.[1]')
    
    echo "Processing account: $account_name ($account_id)"
    
    if ! assume_role "$account_id"; then
        echo "$account_name,$account_id,,Error,Failed to assume role" >> $OUTPUT_FILE
        continue
    fi

    for region in $regions; do
        echo "Fetching roles for region: $region"
        
        roles=$(aws iam list-roles --region "$region" --query "Roles[?!(starts_with(RoleName, 'AWSServiceRoleFor'))].[RoleName,Arn]" --output json)

        for role in $(echo "$roles" | jq -c '.[]'); do
            role_name=$(echo "$role" | jq -r '.[0]')
            role_arn=$(echo "$role" | jq -r '.[1]')
            echo "$account_name,$account_id,$region,$role_name,$role_arn" >> $OUTPUT_FILE
        done
    done

    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done

echo "Script execution completed. Roles saved to $OUTPUT_FILE."
