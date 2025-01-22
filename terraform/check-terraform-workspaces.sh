#!/bin/bash

# Use the first argument as the base directory or default to the current directory
BASE_DIR=${1:-"."}
echo "DEBUG: Base directory is '$BASE_DIR'"

# Output CSV file
OUTPUT_FILE="terraform_workspaces_and_resources.csv"
echo "Working Directory,Workspace,Resource Count" > "$OUTPUT_FILE"

# AWS configuration values (if needed for Terraform remote backends)
export AWS_PAGER=""
export ROOT_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export ROOT_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export ROOT_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN
export ROLE_NAME="ModernisationPlatformAccess"

# Find all Terraform project directories (exclude .terraform subdirectories)
find "$BASE_DIR" -type d ! -path "*/.terraform/*" | while read -r WORKING_DIRECTORY; do
    echo "DEBUG: Checking directory '$WORKING_DIRECTORY'"

    # Skip invalid directories or those that no longer exist
    if [ ! -d "$WORKING_DIRECTORY" ]; then
        echo "Warning: Directory '$WORKING_DIRECTORY' is invalid or no longer exists. Skipping..."
        continue
    fi

    cd "$WORKING_DIRECTORY" || continue

    # Ensure the directory contains Terraform configuration files (.tf)
    if ! ls *.tf > /dev/null 2>&1; then
        echo "No Terraform configuration files found in '$WORKING_DIRECTORY'. Skipping..."
        continue
    fi

    # Initialize Terraform (silent if already initialized)
    terraform init -input=false > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: Terraform initialization failed in '$WORKING_DIRECTORY'. Skipping..."
        continue
    fi

    # List all Terraform workspaces in the directory
    WORKSPACES=$(terraform workspace list 2>/dev/null | sed 's/^[* ]*//')
    if [ -z "$WORKSPACES" ]; then
        echo "No workspaces found in '$WORKING_DIRECTORY'. Skipping..."
        continue
    fi

    # Iterate through each workspace
    for WORKSPACE in $WORKSPACES; do
        echo "--------------------------------------"
        echo "Workspace: $WORKSPACE"

        # Select the workspace
        terraform workspace select "$WORKSPACE" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Error: Unable to select workspace '$WORKSPACE'."
            continue
        fi

        # Count resources in the workspace
        RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l)
        if [ "$RESOURCE_COUNT" -eq 0 ]; then
            echo "Workspace '$WORKSPACE' has no resources."
        else
            echo "Workspace '$WORKSPACE' has $RESOURCE_COUNT resource(s)."
        fi

        # Append results to the CSV file
        echo "$WORKING_DIRECTORY,$WORKSPACE,$RESOURCE_COUNT" >> "$OUTPUT_FILE"
    done

    # Reset AWS credentials after processing the current directory
    export AWS_ACCESS_KEY_ID=$ROOT_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ROOT_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ROOT_AWS_SESSION_TOKEN
    rm -f credentials.json

    # Return to the base directory
    cd "$BASE_DIR" || exit
done

# Cleanup AWS credentials after script execution
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
unset ROOT_AWS_ACCESS_KEY_ID
unset ROOT_AWS_SECRET_ACCESS_KEY
unset ROOT_AWS_SESSION_TOKEN
unset ROLE_NAME

echo "AWS credentials have been cleaned up."
echo "Results have been saved to $OUTPUT_FILE."
