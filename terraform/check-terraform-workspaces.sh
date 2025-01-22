#!/bin/bash

# Base directory to scan for Terraform directories
BASE_DIR="/modernisation-platform/terraform"

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
    echo "================================================================="
    echo "Processing working directory: $WORKING_DIRECTORY"

    # Navigate to the directory
    if [ ! -d "$WORKING_DIRECTORY" ]; then
        echo "Error: Directory '$WORKING_DIRECTORY' does not exist."
        continue
    fi

    cd "$WORKING_DIRECTORY" || continue

    # Check for Terraform configuration files (.tf)
    if ! ls *.tf > /dev/null 2>&1; then
        echo "No Terraform configuration files found in '$WORKING_DIRECTORY'. Skipping..."
        continue
    fi

    # List all Terraform workspaces in the directory
    echo "Listing workspaces for $WORKING_DIRECTORY..."
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
