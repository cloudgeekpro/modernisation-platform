#!/bin/bash

# Check if sufficient arguments are provided
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <s3_bucket_name> <output_csv_file>"
    exit 1
fi

JSON_DIR="./environments"
README_REPO_DIR="./modernisation-platform-environments/terraform/environments"

# S3 bucket and file details
bucket_name="$1"
csv_file="$2"
s3_file_path="s3://$bucket_name/data/$csv_file"

# Function to extract member readme info
extract_member_readme_info() {
    local readme_path=$1
    local service_urls="N/A"
    local incident_hours="N/A"
    local incident_contact_details="N/A"

    if [[ -f "$readme_path" ]]; then
        # Extract service URLs
        service_urls=$(awk '/### \*\*Service URLs:\*\*/ {flag=1; next} /^###/ {flag=0} flag' "$readme_path" \
        | grep -Eo 'https?://[a-zA-Z0-9./?=_-]*' \
        | while read -r url; do
            if [[ "$url" =~ dev|development ]]; then
                echo "dev: $url"
            elif [[ "$url" =~ preproduction|staging ]]; then
                echo "preprod: $url"
            elif [[ "$url" =~ uat|test ]]; then
                echo "test: $url"
            else
                echo "prod: $url"
            fi
        done | sort -u | paste -sd "|" -)
        
        # Extract incident details
        incident_hours=$(awk '/### \*\*Incident response hours:\*\*/ {flag=1; next} /^###/ {flag=0} flag' "$readme_path" | tr '\n' ' ' | sed 's/<!--.*-->//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        incident_contact_details=$(awk '/### \*\*Incident contact details:\*\*/ {flag=1; next} /^###/ {flag=0} flag' "$readme_path" | tr '\n' ' ' | sed 's/<!--.*-->//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/[<`>]//g')
    fi

    # Assign defaults if empty
    service_urls=${service_urls:-N/A}
    incident_hours=${incident_hours:-N/A}
    incident_contact_details=${incident_contact_details:-N/A}
    
    echo "$incident_hours|$incident_contact_details|$service_urls"
}

# Clean data for CSV line formation
clean_field() {
    local field="$1"
    echo "$field" | sed 's/\n/ /g' | sed 's/\r//g' | sed 's/,/|/g' | sed 's/"/""/g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Output the header for CSV
echo "Account Name,AWS Account ID,Slack Channel,Infrastructure Support Email,Incident Hours,Incident Contact Details,Service URLs" > $csv_file

# Loop through each JSON file in the JSON_DIR
for json_file in "$JSON_DIR"/*.json; do
    if [[ -f "$json_file" ]]; then
        # Skip the file if the application tag is modernisation-platform
        application=$(jq -r '.tags.application // empty' "$json_file")
        if [[ "$application" == "modernisation-platform" || "$application" == "example" ]]; then
            echo "Skipping $json_file because application tag is modernisation-platform or example"
            continue
        fi

        # Use the file name (without .json) as base_app_name
        base_app_name=$(basename "$json_file" .json)

        readme_path="$README_REPO_DIR/$base_app_name/README.md"

        service_info=$(extract_member_readme_info "$readme_path")
        incident_hours=$(echo "$service_info" | cut -d'|' -f1)
        incident_contact_details=$(echo "$service_info" | cut -d'|' -f2)

        infra_support_email=$(jq -r '.tags["infrastructure-support"] // .tags.owner // "N/A"' "$json_file")
        slack_channel=$(jq -r '.tags["slack-channel"] // "N/A"' "$json_file")

        environments=$(jq -c '.environments[]' "$json_file")

        echo "$environments" | while read -r env; do
            env_name=$(echo "$env" | jq -r '.name')
            account_name="${base_app_name}-${env_name}"

            service_url="N/A"
            if [[ -n "$service_info" ]]; then
                service_url=$(echo "$service_info" | grep -o "\b${env_name}: https://[^|]*")
            fi

            if [[ -z "$service_url" ]]; then
                case "$env_name" in
                    dev|development)
                        service_url=$(echo "$service_info" | grep -o "\bdev: https://[^|]*")
                        ;;
                    test|uat)
                        service_url=$(echo "$service_info" | grep -o "\btest: https://[^|]*")
                        ;;
                    preproduction|staging)
                        service_url=$(echo "$service_info" | grep -o "\bpreprod: https://[^|]*")
                        ;;
                    *)
                        service_url=$(echo "$service_info" | grep -o "\bprod: https://[^|]*")
                        ;;
                esac
            fi

            # Retrieve the AWS account ID from the environment variable
            aws_account_id=$(echo "$ENVIRONMENT_MANAGEMENT" | jq -r --arg key "$account_name" '.account_ids[$key] // "N/A"')

            # Assign "N/A" if still empty
            account_name=${account_name:-N/A}
            slack_channel=${slack_channel:-N/A}
            infra_support_email=${infra_support_email:-N/A}
            incident_hours=${incident_hours:-N/A}
            incident_contact_details=${incident_contact_details:-N/A}
            service_url=${service_url:-N/A}
            aws_account_id=${aws_account_id:-N/A}

            # Clean the data for CSV formatting
            account_name=$(clean_field "$account_name")
            slack_channel=$(clean_field "$slack_channel")
            infra_support_email=$(clean_field "$infra_support_email")
            incident_hours=$(clean_field "$incident_hours")
            incident_contact_details=$(clean_field "$incident_contact_details")
            service_url=$(clean_field "$service_url")
            aws_account_id=$(clean_field "$aws_account_id")
            service_url=$(echo "$service_url" | sed -E 's/(dev|preprod|test|prod): //g')

            # Create CSV line with double quotes
            csv_line="\"$account_name\",\"$aws_account_id\",\"$slack_channel\",\"$infra_support_email\",\"$incident_hours\",\"$incident_contact_details\",\"$service_url\""

            # Append only if the row doesn't already exist
            if ! grep -qF "$csv_line" $csv_file; then
                echo "$csv_line" >> $csv_file
            fi
        done
    fi
done

# Upload $csv_file to the S3 bucket
aws s3 cp $csv_file $s3_file_path
rm $csv_file