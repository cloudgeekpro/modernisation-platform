#!/bin/bash

# Function to count resources in a given workspace
count_resources_in_workspace() {
  local terraform_dir="$1"
  local workspace="$2"

  # Switch to the specified workspace
  if ! (cd "$terraform_dir" && terraform workspace select "$workspace" > /dev/null 2>&1); then
      echo "Error: Failed to select workspace '$workspace' in '$terraform_dir'" >&2
      return 1
  fi


  # Get Terraform state as JSON
  state_json=$(terraform state pull 2>/dev/null)

  if [[ -z "$state_json" ]]; then
      echo "Error: Failed to pull state for workspace '$workspace' in '$terraform_dir'" >&2
      return 1
  fi


  # Check if the state is empty
    if [[ "$state_json" == *"\"resources\": []"* || "$state_json" == *'"resources": null'* ]]; then
      return 0
    fi

  # Count the resources (we use jq to count the items in array)
  resource_count=$(echo "$state_json" | jq '.resources | length' 2>/dev/null)

   if [[ -z "$resource_count" ]]; then
        echo "Error parsing resources from state for workspace '$workspace' in '$terraform_dir'" >&2
        return 1
   fi

  echo "$resource_count"
}

# Use the first argument as the base directory or default to the current directory
BASE_DIR=${1:-"."}
echo "DEBUG: Base directory is '$BASE_DIR'" >&2

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
find "$BASE_DIR" -type d ! -path "*/.terraform/*" -print0 | while IFS= read -r -d $'\0' WORKING_DIRECTORY; do
    echo "DEBUG: Checking directory '$WORKING_DIRECTORY'" >&2

    # Skip invalid directories or those that no longer exist
    if [ ! -d "$WORKING_DIRECTORY" ]; then
        echo "Warning: Directory '$WORKING_DIRECTORY' is invalid or no longer exists. Skipping..." >&2
        continue
    fi


    # Ensure the directory contains Terraform configuration files (.tf)
    if ! find "$WORKING_DIRECTORY" -maxdepth 1 -name "*.tf" -print -quit > /dev/null; then
        echo "No Terraform configuration files found in '$WORKING_DIRECTORY'. Skipping..." >&2
        continue
    fi

    # Initialize Terraform (silent if already initialized)
    terraform init -input=false -no-color > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: Terraform initialization failed in '$WORKING_DIRECTORY'. Skipping..." >&2
        continue
    fi

    # Get the list of workspaces using terraform workspace list
    WORKSPACES=$(cd "$WORKING_DIRECTORY" && terraform workspace list | grep -v '*' 2>/dev/null )
    if [[ -z "$WORKSPACES" ]]; then
        echo "No workspaces found in '$WORKING_DIRECTORY'. Skipping..." >&2
        continue
    fi

   # Iterate through each workspace
   while IFS= read -r WORKSPACE; do
      echo "--------------------------------------" >&2
      echo "Workspace: $WORKSPACE" >&2

      # Count resources and display the result
       resource_count=$(count_resources_in_workspace "$WORKING_DIRECTORY" "$WORKSPACE")
       if [[ $? -eq 0 ]]; then
          if [[ -z "$resource_count" ]]; then
               echo "Workspace '$WORKSPACE' has no resources." >&2
               resource_count=0
          else
            echo "Workspace '$WORKSPACE' has $resource_count resource(s)." >&2
          fi
           # Append results to the CSV file
          echo "$WORKING_DIRECTORY,$WORKSPACE,$resource_count" >> "$OUTPUT_FILE"
      fi
  done <<< "$WORKSPACES"

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

echo "AWS credentials have been cleaned up." >&2
echo "Results have been saved to $OUTPUT_FILE." >&2