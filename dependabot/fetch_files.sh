#!/bin/bash
# Script to fetch all files from a GitHub directory recursively
# Usage: ./fetch_files.sh <owner> <repo> <branch> <path> <github_token>
# Output: JSON array of file paths

OWNER=$1
REPO=$2
BRANCH=$3
PATH_PREFIX=$4
GITHUB_TOKEN=$5

# Function to recursively list files
list_files_recursive() {
    local current_path=$1
    local api_url="https://api.github.com/repos/${OWNER}/${REPO}/contents/${current_path}?ref=${BRANCH}"

    # Make API call
    local response
    response=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    "$api_url")

    # Check if response is an array
    if echo "$response" | jq -e 'if type == "array" then true else false end' > /dev/null 2>&1; then
        # Iterate through each item
        echo "$response" | jq -c '.[]' | while read -r item; do
            local item_type
            local item_path
            item_type=$(echo "$item" | jq -r '.type')
            item_path=$(echo "$item" | jq -r '.path')

            if [ "$item_type" = "file" ]; then
                # Output the file path
                echo "$item_path"
            elif [ "$item_type" = "dir" ]; then
                # Recurse into directory
                list_files_recursive "$item_path"
            fi
        done
    fi
}

# Start recursive listing and output as JSON array
echo "["
first=true
while IFS= read -r file_path; do
    if [ -n "$file_path" ]; then
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo "  \"$file_path\""
    fi
done < <(list_files_recursive "$PATH_PREFIX")
echo "]"
