#!/bin/bash

# Smart script to protect GitLab environments based on patterns
# Usage: ./protect_environments.sh <project_path> <env_pattern>
# Example: ./protect_environments.sh "your-group/your-project" "dev"
# Example: ./protect_environments.sh "your-group/your-project" "qa"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <project_path> <env_pattern>"
    echo "Example: $0 'your-group/your-project' 'dev'"
    echo "Example: $0 'your-group/your-project' 'qa'"
    echo "Example: $0 'your-group/your-project' 'prod'"
    echo "Example: $0 'your-group/your-project' 'all'"
    exit 1
fi

if [ -z "$GITLAB_TOKEN" ]; then
    echo "Error: GITLAB_TOKEN environment variable must be set"
    exit 1
fi

PROJECT_PATH="$1"
ENV_PATTERN="$2"
GITLAB_BASE_URL="https://gitlab.example.com/api/v4"

# URL encode the project path
PROJECT_PATH_ENCODED=$(echo "$PROJECT_PATH" | sed 's/\//%2F/g')

echo "Getting project information for: $PROJECT_PATH"
echo "=============================================="

# Get project ID
PROJECT_INFO=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_BASE_URL/projects/$PROJECT_PATH_ENCODED")

if ! echo "$PROJECT_INFO" | jq -e '.id' >/dev/null 2>&1; then
    echo "Error: Could not find project or invalid response"
    echo "Response: $PROJECT_INFO"
    exit 1
fi

PROJECT_ID=$(echo "$PROJECT_INFO" | jq -r '.id')
PROJECT_NAME=$(echo "$PROJECT_INFO" | jq -r '.name')

echo "✓ Found project: $PROJECT_NAME (ID: $PROJECT_ID)"
echo ""

# Get all environments
echo "Fetching environments..."
ENVIRONMENTS_JSON=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_BASE_URL/projects/$PROJECT_ID/environments")

if ! echo "$ENVIRONMENTS_JSON" | jq -e '.' >/dev/null 2>&1; then
    echo "Error: Could not fetch environments"
    echo "Response: $ENVIRONMENTS_JSON"
    exit 1
fi

# Get existing protected environments
echo "Checking existing protected environments..."
PROTECTED_ENVS_JSON=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_BASE_URL/projects/$PROJECT_ID/protected_environments")

PROTECTED_ENV_NAMES=""
if echo "$PROTECTED_ENVS_JSON" | jq -e '.' >/dev/null 2>&1; then
    PROTECTED_ENV_NAMES=$(echo "$PROTECTED_ENVS_JSON" | jq -r '.[].name' 2>/dev/null || echo "")
fi

# Filter environments by pattern and extract names
if [ "$ENV_PATTERN" = "all" ]; then
    # Match all environments
    MATCHING_ENVS=$(echo "$ENVIRONMENTS_JSON" | jq -r '.[].name')
    echo "Pattern: all environments"
else
    # Automatically add wildcard to pattern
    GREP_PATTERN="${ENV_PATTERN}.*"
    MATCHING_ENVS=$(echo "$ENVIRONMENTS_JSON" | jq -r '.[].name' | grep "^$GREP_PATTERN$")
    echo "Pattern: ${ENV_PATTERN}* (matching environments starting with '$ENV_PATTERN')"
fi

if [ -z "$MATCHING_ENVS" ]; then
    echo "No environments found matching pattern: $ENV_PATTERN"
    exit 1
fi

# Filter out already protected environments
UNPROTECTED_ENVS=""
ALREADY_PROTECTED=()

while IFS= read -r env_name; do
    if echo "$PROTECTED_ENV_NAMES" | grep -q "^$env_name$"; then
        ALREADY_PROTECTED+=("$env_name")
    else
        if [ -z "$UNPROTECTED_ENVS" ]; then
            UNPROTECTED_ENVS="$env_name"
        else
            UNPROTECTED_ENVS="$UNPROTECTED_ENVS"$'\n'"$env_name"
        fi
    fi
done <<< "$MATCHING_ENVS"

# Count environments
TOTAL_MATCHING=$(echo "$MATCHING_ENVS" | wc -l)
ALREADY_PROTECTED_COUNT=${#ALREADY_PROTECTED[@]}
UNPROTECTED_COUNT=0
if [ -n "$UNPROTECTED_ENVS" ]; then
    UNPROTECTED_COUNT=$(echo "$UNPROTECTED_ENVS" | wc -l)
fi

echo ""
echo "Environment Analysis:"
echo "=============================================="
echo "Total matching environments: $TOTAL_MATCHING"
echo "Already protected: $ALREADY_PROTECTED_COUNT"
echo "Need protection: $UNPROTECTED_COUNT"
echo ""

if [ $ALREADY_PROTECTED_COUNT -gt 0 ]; then
    echo "Already protected environments (will be skipped):"
    printf '%s\n' "${ALREADY_PROTECTED[@]}"
    echo ""
fi

if [ $UNPROTECTED_COUNT -eq 0 ]; then
    echo "All matching environments are already protected. Nothing to do!"
    exit 0
fi

echo "Environments to be protected:"
echo "$UNPROTECTED_ENVS"
echo "=============================================="
echo ""

# Ask for confirmation
read -p "Do you want to protect these $UNPROTECTED_COUNT environment(s)? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo ""
echo "Starting to protect environments..."
echo "=============================================="

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0

# Loop through each unprotected environment and protect it
while IFS= read -r env_name; do
    echo "Protecting environment: $env_name"
    
    response=$(curl -s -X POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --header "Content-Type: application/json" \
        --data "{\"name\": \"$env_name\", \"deploy_access_levels\": [{\"access_level\": 30}], \"approval_rules\": [{\"access_level\": 30, \"required_approvals\": 1}]}" \
        "$GITLAB_BASE_URL/projects/$PROJECT_ID/protected_environments")
    
    # Check if the request was successful
    if echo "$response" | jq -e '.name' >/dev/null 2>&1; then
        echo "✓ Successfully protected: $env_name"
        ((SUCCESS_COUNT++))
    else
        echo "✗ Failed to protect: $env_name"
        echo "  Response: $response"
        ((FAIL_COUNT++))
    fi
    
    # Small delay to avoid overwhelming the API
    sleep 0.5
done <<< "$UNPROTECTED_ENVS"

echo "=============================================="
echo "Environment protection completed!"
echo "✓ Successfully protected: $SUCCESS_COUNT environment(s)"
echo "✗ Failed to protect: $FAIL_COUNT environment(s)"
if [ $ALREADY_PROTECTED_COUNT -gt 0 ]; then
    echo "⚠ Skipped (already protected): $ALREADY_PROTECTED_COUNT environment(s)"
fi
echo ""
echo "NOTE: You still need to manually enable 'Allow pipeline triggerer to approve deployment'"
echo "for each environment through the GitLab UI:"
echo "Settings > CI/CD > Protected environments > Approval options"
echo ""
echo "Settings URL: https://gitlab.example.com/$PROJECT_PATH/-/settings/ci_cd#js-protected-environments-settings"