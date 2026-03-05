#!/bin/bash
# Script to find the latest spec file from a cloned repository using commit history
# Usage: ./find_latest_spec.sh <repo_url> <branch> <base_path> <spec_regex>
# Output: JSON with {"filePath": "path/to/file", "apiVersion": "extracted_version", "lastCommitDate": "date"}

set -e

REPO_URL=$1
BRANCH=$2
BASE_PATH=$3
SPEC_REGEX=$4

# Create a temporary directory for cloning
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "[DEBUG] Cloning repository: $REPO_URL (branch: $BRANCH)" >&2

# Clone the repository (full clone to get commit history)
git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$TEMP_DIR/repo" >&2 2>&1 || {
    echo "[ERROR] Failed to clone repository" >&2
    exit 1
}

cd "$TEMP_DIR/repo"

# Navigate to base path if specified
if [ -n "$BASE_PATH" ]; then
    if [ -d "$BASE_PATH" ]; then
        cd "$BASE_PATH"
    else
        echo "[ERROR] Base path not found: $BASE_PATH" >&2
        exit 1
    fi
fi

echo "[DEBUG] Searching for files matching regex: $SPEC_REGEX" >&2

# Find all files matching the regex pattern
# Strategy: Select file with highest version number in path (v4.2 > v4.1 > v3.0)
# If versions are equal, use most recent commit timestamp
BEST_FILE=""
BEST_COMMIT_DATE=""
BEST_COMMIT_TIMESTAMP=0
BEST_VERSION_NUM=0
BEST_VERSION_STRING=""

while IFS= read -r file; do
    # Get just the filename
    filename=$(basename "$file")

    # Skip Collection files (Postman collections)
    if [[ "$filename" == *"Collection"* ]]; then
        continue
    fi

    # Check if filename matches the regex pattern
    if echo "$filename" | grep -E "$SPEC_REGEX" > /dev/null; then
        echo "[DEBUG] Match found: $file" >&2

        # CHANGE 2: Extract version number from path with support for semantic versioning
        # Supports: /v4/, /v4.2/, /v4.2.1/, etc.
        version_num=0
        version_string=""
        if [[ "$file" =~ /v([0-9]+(\.[0-9]+)*)/ ]]; then
            version_string="${BASH_REMATCH[1]}"

            # Convert to comparable number: v2.1.3 -> 2001003 (assumes max 999 for minor/patch)
            IFS='.' read -ra VERSION_PARTS <<< "$version_string"
            major="${VERSION_PARTS[0]:-0}"
            minor="${VERSION_PARTS[1]:-0}"
            patch="${VERSION_PARTS[2]:-0}"

            # Create comparable version number (major * 1000000 + minor * 1000 + patch)
            version_num=$((major * 1000000 + minor * 1000 + patch))
        fi

        # Get the last commit date for this file (Unix timestamp for comparison)
        commit_timestamp=$(git log -1 --format="%ct" -- "$file" 2>/dev/null || echo "0")
        commit_date=$(git log -1 --format="%ci" -- "$file" 2>/dev/null || echo "unknown")

        echo "[DEBUG]   Version: v$version_string (comparable: $version_num), Last commit: $commit_date (timestamp: $commit_timestamp)" >&2

        # Compare: first by version number, then by commit timestamp
        is_better=0
        if [ "$version_num" -gt "$BEST_VERSION_NUM" ]; then
            is_better=1
        elif [ "$version_num" -eq "$BEST_VERSION_NUM" ] && [ "$commit_timestamp" -gt "$BEST_COMMIT_TIMESTAMP" ]; then
            is_better=1
        fi

        if [ "$is_better" -eq 1 ]; then
            BEST_FILE="$file"
            BEST_COMMIT_DATE="$commit_date"
            BEST_COMMIT_TIMESTAMP=$commit_timestamp
            BEST_VERSION_NUM=$version_num
            BEST_VERSION_STRING=$version_string
        fi
    fi
done < <(find . -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" \))

if [ -z "$BEST_FILE" ]; then
    echo "[ERROR] No matching files found" >&2
    exit 1
fi

echo "[DEBUG] Best match: $BEST_FILE (version: v$BEST_VERSION_STRING, last commit: $BEST_COMMIT_DATE)" >&2

# Read the file content and extract version from info.version
FILE_CONTENT=$(cat "$BEST_FILE")

# Try to extract version using grep and sed
# For JSON: "version": "value"
# For YAML: version: value
API_VERSION=""

if [[ "$FILE_CONTENT" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    # JSON format
    API_VERSION="${BASH_REMATCH[1]}"
elif echo "$FILE_CONTENT" | grep -A 20 "^info:" | grep -E "^[[:space:]]+version:" > /dev/null; then
    # YAML format
    API_VERSION=$(echo "$FILE_CONTENT" | grep -A 20 "^info:" | grep -E "^[[:space:]]+version:" | head -1 | sed -E 's/^[[:space:]]+version:[[:space:]]+//; s/["'\'']//g')
fi

if [ -z "$API_VERSION" ]; then
    echo "[ERROR] Could not extract API version from spec file" >&2
    exit 1
fi

echo "[DEBUG] Extracted API version: $API_VERSION" >&2

# Get the relative path from the base directory
# Remove leading ./ from BEST_FILE first
BEST_FILE="${BEST_FILE#./}"

if [ -n "$BASE_PATH" ]; then
    RELATIVE_PATH="$BASE_PATH/$BEST_FILE"
else
    RELATIVE_PATH="$BEST_FILE"
fi

# Output JSON result (to stdout)
cat <<EOF
{
  "filePath": "$RELATIVE_PATH",
  "apiVersion": "$API_VERSION",
  "lastCommitDate": "$BEST_COMMIT_DATE"
}
EOF
