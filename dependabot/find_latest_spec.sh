#!/bin/bash
# Script to find the latest spec file from a cloned repository
# Usage: ./find_latest_spec.sh <repo_url> <branch> <base_path> <spec_regex>
# Output: JSON with {"filePath": "path/to/file", "version": "extracted_version"}

set -e

REPO_URL=$1
BRANCH=$2
BASE_PATH=$3
SPEC_REGEX=$4

# Create a temporary directory for cloning
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "[DEBUG] Cloning repository: $REPO_URL (branch: $BRANCH)" >&2

# Clone the repository (shallow clone for speed)
git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO_URL" "$TEMP_DIR/repo" >&2 2>&1 || {
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

# Find all files recursively
# Filter by regex pattern (matching filename only, not full path)
# Extract version numbers and find the best match

BEST_FILE=""
BEST_ROLLOUT=0
BEST_MAJOR=0
BEST_MINOR=0

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

        # Extract rollout number (e.g., Rollouts/148901/v4)
        rollout=0
        if [[ "$file" =~ Rollouts/([0-9]+) ]]; then
            rollout="${BASH_REMATCH[1]}"
        fi

        # Extract version from path (e.g., /v4/)
        major=0
        minor=0
        if [[ "$file" =~ /v([0-9]+)/ ]]; then
            major="${BASH_REMATCH[1]}"
        fi

        # Extract version from filename (e.g., swagger-v2.1.json)
        if [[ "$filename" =~ -v([0-9]+)\.([0-9]+)\. ]]; then
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
        elif [[ "$filename" =~ -v([0-9]+)\.json ]]; then
            major="${BASH_REMATCH[1]}"
            minor=0
        fi

        echo "[DEBUG]   Rollout: $rollout, Major: $major, Minor: $minor" >&2

        # Compare: first by rollout, then by major, then by minor
        is_better=0
        if [ "$rollout" -gt "$BEST_ROLLOUT" ]; then
            is_better=1
        elif [ "$rollout" -eq "$BEST_ROLLOUT" ]; then
            if [ "$major" -gt "$BEST_MAJOR" ]; then
                is_better=1
            elif [ "$major" -eq "$BEST_MAJOR" ] && [ "$minor" -gt "$BEST_MINOR" ]; then
                is_better=1
            fi
        fi

        if [ "$is_better" -eq 1 ]; then
            BEST_FILE="$file"
            BEST_ROLLOUT=$rollout
            BEST_MAJOR=$major
            BEST_MINOR=$minor
        fi
    fi
done < <(find . -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" \))

if [ -z "$BEST_FILE" ]; then
    echo "[ERROR] No matching files found" >&2
    exit 1
fi

echo "[DEBUG] Best match: $BEST_FILE (rollout: $BEST_ROLLOUT, version: $BEST_MAJOR.$BEST_MINOR)" >&2

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
  "rollout": $BEST_ROLLOUT,
  "majorVersion": $BEST_MAJOR,
  "minorVersion": $BEST_MINOR
}
EOF
