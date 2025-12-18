#!/bin/bash
# -------------------------------------------------------------------
# gitlab_mirror.sh
#
# Clones or updates Git repositories from multiple GitLab groups and their
# subgroups to a local directory, running in parallel.
#
# Features:
#   - Clones or updates repositories from specified GitLab groups
#   - Handles both main groups and subgroups
#   - Runs cloning/updating processes in parallel for efficiency
#   - Logs actions and errors
#
# Usage:
#   ./gitlab_mirror.sh [-t TOKEN] -g GROUP_PATHS
#     -t TOKEN       : GitLab personal access token (optional if GITLAB_TOKEN is set)
#     -g GROUP_PATHS : Space-separated list of GitLab group paths (e.g., "my-group my-other-group")
#
# Dependencies:
#   - jq
#   - GitLab personal access token with necessary permissions
#
# -------------------------------------------------------------------

### Dependency Check (fail early if missing)
REQUIRED_TOOLS=(jq curl git)
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "\033[0;31m[FATAL] Required dependency '$tool' is not installed.\033[0m" >&2
    echo "Install it on Ubuntu with: sudo apt-get update && sudo apt-get install -y $tool" >&2
    exit 2
  fi
done

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging Functions
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [WARNING] $1${NC}"
}

error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1${NC}" >&2
}

fatal_error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [FATAL] $1${NC}" >&2
    exit 1
}

# Debug logging function
debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1"
    fi
}

usage() {
  echo "Usage: $0 [-t TOKEN] [-s] [-d] -g GROUP_PATHS"
  echo "  -t TOKEN       : Your GitLab personal access token (optional if GITLAB_TOKEN environment variable is set)"
  echo "  -g GROUP_PATHS : Space-separated list of GitLab group paths (e.g., \"my-group my-other-group\")"
  echo "  -s             : Skip connectivity test (useful for slow networks)"
  echo "  -d             : Enable debug mode with verbose output"
  exit 1
}

# Parse command-line options
SKIP_CONNECTIVITY_TEST=false
DEBUG_MODE=false
while getopts ":t:g:sd" opt; do
  case $opt in
    t) TOKEN="$OPTARG" ;;
    g) GROUP_PATHS="$OPTARG" ;;
    s) SKIP_CONNECTIVITY_TEST=true ;;
    d) DEBUG_MODE=true ;;
    \?) echo "Invalid option -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

# Check if the token is provided as an environment variable
if [ -z "$TOKEN" ]; then
  if [ -z "$GITLAB_TOKEN" ]; then
    echo "Error: GitLab token is missing. Please provide it using the -t flag or set the GITLAB_TOKEN environment variable."
    usage
  else
    TOKEN="$GITLAB_TOKEN"
  fi
fi

# Check if the group paths are provided
if [ -z "$GROUP_PATHS" ]; then
  echo "Error: Group paths are required."
  usage
fi

# Convert the group paths into an array
IFS=' ' read -r -a GROUPS_ARRAY <<< "$GROUP_PATHS"

# Set local directory
LOCAL_DIR="$HOME/gitlab-repos"

# Function to check Git credentials
check_git_credentials() {
  if [ -f ~/.git-credentials ] && (grep -q "gitlab.com" ~/.git-credentials || grep -q "gitlab.example.com" ~/.git-credentials); then
    if [ "$(git config --global credential.helper)" = "store" ]; then
      return 0
    fi
  fi
  echo "Git credentials for GitLab are not set up."
  echo "To set up Git credentials, please run the following commands:"
  echo "git config --global credential.helper store"
  echo "echo \"https://oauth2:YOUR_GITLAB_TOKEN@gitlab.example.com\" > ~/.git-credentials"
  echo "chmod 600 ~/.git-credentials"
  echo "Replace YOUR_GITLAB_TOKEN with your actual GitLab personal access token."
  echo "After setting up the credentials, please run this script again."
  return 1
}

# Function to ensure HTTPS URL
ensure_https_url() {
  local url="$1"
  echo "$url" | sed 's#^http://#https://#'
}

# Function to URL encode group path
url_encode() {
  local string="$1"
  echo "$string" | sed 's#/#%2F#g'
}

# Function to reset repository to default branch
reset_to_default_branch() {
  local repo_dir="$1"
  log "Resetting $repo_dir to default branch"
  
  # Check if repo directory exists and has .git
  if [ ! -d "$repo_dir/.git" ]; then
    error "Repository directory $repo_dir is not a valid git repository"
    return 1
  fi
  
  # Stash any local changes
  if ! timeout 30 git -C "$repo_dir" diff-index --quiet HEAD -- 2>/dev/null; then
    log "Stashing local changes in $repo_dir"
    timeout 30 git -C "$repo_dir" stash push -m "Auto-stash by gitlab_mirror.sh" 2>/dev/null || true
  fi
  
  # Fetch latest changes first (this will test authentication)
  log "Fetching latest changes for $repo_dir"
  if ! timeout 60 git -C "$repo_dir" fetch origin 2>/dev/null; then
    log_warning "Failed to fetch from origin for $repo_dir - this may be due to authentication or network issues"
    # Don't return error yet, try to work with what we have
  fi
  
  # Get the default branch name with better error handling
  local default_branch
  default_branch=$(timeout 30 git -C "$repo_dir" remote show origin 2>/dev/null | grep 'HEAD branch' | cut -d' ' -f5 | tr -d '[:space:]')
  
  # Fallback methods if the above fails
  if [ -z "$default_branch" ] || [ "$default_branch" = "" ]; then
    debug "Trying alternative method to get default branch for $repo_dir"
    default_branch=$(timeout 30 git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' | tr -d '[:space:]')
  fi
  
  # Final fallback to common branch names
  if [ -z "$default_branch" ] || [ "$default_branch" = "" ]; then
    debug "Using fallback branch detection for $repo_dir"
    for branch in main master develop; do
      if timeout 10 git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
        default_branch="$branch"
        break
      fi
    done
  fi
  
  # If still no branch, try to get current branch
  if [ -z "$default_branch" ] || [ "$default_branch" = "" ]; then
    debug "Trying to use current branch for $repo_dir"
    default_branch=$(timeout 30 git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '[:space:]')
  fi
  
  # Validate we have a branch name
  if [ -z "$default_branch" ] || [ "$default_branch" = "" ]; then
    error "Could not determine default branch for $repo_dir"
    return 1
  fi
  
  debug "Using branch: $default_branch for $repo_dir"
  
  # Checkout the default branch
  if ! timeout 30 git -C "$repo_dir" checkout "$default_branch" 2>/dev/null; then
    log_warning "Failed to checkout $default_branch for $repo_dir, but continuing"
  fi
  
  # Try to reset to origin (this might fail if fetch failed)
  if timeout 30 git -C "$repo_dir" reset --hard "origin/$default_branch" 2>/dev/null; then
    log_success "Successfully reset $repo_dir to origin/$default_branch"
  else
    log_warning "Could not reset to origin/$default_branch for $repo_dir (may be due to network/auth issues)"
  fi
  
  return 0
}

# Function to update repository
update_repository() {
  local repo_dir="$1"
  log "Updating $repo_dir"
  
  # Fetch all remotes
  if ! timeout 60 git -C "$repo_dir" fetch --all 2>/dev/null; then
    log_warning "Failed to fetch all remotes for $repo_dir - may be due to authentication or network issues"
    # Don't fail completely, try to work with what we have
  fi
  
  # Get current branch
  local current_branch
  current_branch=$(timeout 30 git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '[:space:]')
  
  if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
    log_warning "Could not determine current branch for $repo_dir"
    return 1
  fi
  
  debug "Current branch: $current_branch for $repo_dir"
  
  # Pull latest changes
  if timeout 60 git -C "$repo_dir" pull origin "$current_branch" 2>/dev/null; then
    log_success "Successfully updated $repo_dir on branch $current_branch"
    return 0
  else
    log_warning "Failed to pull origin/$current_branch for $repo_dir - may be due to authentication or network issues"
    log "Repository $repo_dir is on branch $current_branch but could not be updated"
    return 0  # Don't fail completely, the repo is still in a usable state
  fi
}

# Function to test repository access
test_repository_access() {
  local repo_url="$1"
  local repo_path="$2"
  
  # Extract the repository ID from the API for permission checking
  local gitlab_url
  if [[ "$repo_path" == *"custom"* ]]; then
    gitlab_url="https://gitlab.example.com/api/v4"
  else
    gitlab_url="https://gitlab.com/api/v4"
  fi
  
  local encoded_repo_path=$(url_encode "$repo_path")
  local project_api_url="$gitlab_url/projects/$encoded_repo_path"
  
  debug "Testing repository access for: $repo_path"
  debug "Project API URL: $project_api_url"
  
  local api_response=$(curl -s -w "HTTP_CODE:%{http_code}" \
    --connect-timeout 5 \
    --max-time 15 \
    --header "PRIVATE-TOKEN: $TOKEN" \
    "$project_api_url" 2>/dev/null)
  
  local http_code=$(echo "$api_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
  
  if [ "$http_code" = "200" ]; then
    debug "Repository access test passed for: $repo_path"
    return 0
  elif [ "$http_code" = "404" ]; then
    log_warning "Repository not found or no access: $repo_path"
    return 1
  elif [ "$http_code" = "403" ]; then
    log_warning "Access denied to repository: $repo_path"
    return 1
  else
    debug "Repository access test inconclusive for: $repo_path (HTTP $http_code)"
    return 0  # Continue anyway
  fi
}

# Function to clean up a problematic repository
cleanup_repository() {
  local repo_dir="$1"
  log_warning "Cleaning up problematic repository: $repo_dir"
  
  if [ -d "$repo_dir" ]; then
    # Remove the directory and try fresh clone
    rm -rf "$repo_dir"
    log "Removed problematic repository directory: $repo_dir"
    return 0
  fi
  return 1
}

# Function to clone or pull a repository
clone_or_pull() {
  local repo_path="$1"
  local repo_url="$2"
  local repo_dir="$LOCAL_DIR/$repo_path"
  log "***** Cloning or updating: $repo_path *****"
  repo_url=$(ensure_https_url "$repo_url")
  
  # Test repository access first (only for cloning, not updating)
  if [ ! -d "$repo_dir" ] && ! test_repository_access "$repo_url" "$repo_path"; then
    log_warning "Skipping $repo_path due to access restrictions"
    return 1
  fi
  
  if [ -d "$repo_dir" ]; then
    # Check if it's a valid git repository
    if [ ! -d "$repo_dir/.git" ]; then
      log_warning "$repo_dir exists but is not a git repository, cleaning up"
      cleanup_repository "$repo_dir"
    else
      # Try to reset to default branch
      if ! reset_to_default_branch "$repo_dir"; then
        log_warning "Failed to reset $repo_path, trying cleanup and fresh clone"
        cleanup_repository "$repo_dir"
      else
        # Try to update
        update_repository "$repo_dir"
        return 0
      fi
    fi
  fi
  
  # Clone the repository (either fresh or after cleanup)
  if [ -n "$repo_url" ]; then
    log "Cloning $repo_path from $repo_url"
    
    # Create parent directory if needed
    mkdir -p "$(dirname "$repo_dir")"
    
    if timeout 120 git clone "$repo_url" "$repo_dir" 2>/dev/null; then
      log_success "Successfully cloned $repo_path"
      return 0
    else
      log_warning "Failed to clone $repo_path - may be due to authentication or network issues"
      return 1
    fi
  else
    log_warning "Skipping project with empty URL: $repo_path"
    return 1
  fi
}

# Function to get and process all projects and subgroups
get_all_projects_and_subgroups() {
  local group_path="$1"
  local gitlab_url="$2"
  local encoded_group_path=$(url_encode "$group_path")
  local api_url="$gitlab_url/groups/$encoded_group_path/projects?include_subgroups=true&per_page=100"
  
  log "Fetching projects for group: $group_path"
  log "API URL: $api_url"
  
  api_url=$(ensure_https_url "$api_url")
  local api_response=$(curl -s -w "HTTP_CODE:%{http_code}" \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 2 \
    --header "PRIVATE-TOKEN: $TOKEN" \
    "$api_url" 2>/dev/null)
  
  debug "Raw API response: $api_response"
  
  # Extract HTTP status code
  local http_code=$(echo "$api_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
  local response_body=$(echo "$api_response" | sed 's/HTTP_CODE:[0-9]*$//')
  
  log "HTTP Status Code: $http_code"
  
  if [ "$http_code" != "200" ]; then
    error "API request failed with HTTP $http_code for group: $group_path"
    log "Response: $response_body"
    
    # Show troubleshooting tips on first failure
    if [ ! -f /tmp/.gitlab_mirror_tips_shown ]; then
      show_troubleshooting_tips
      touch /tmp/.gitlab_mirror_tips_shown
    fi
    
    return 1
  fi
  
  if [ -z "$response_body" ]; then
    log_warning "Empty response for group: $group_path"
    return 1
  fi
  
  if ! echo "$response_body" | jq -e 'type == "array"' > /dev/null 2>&1; then
    log_warning "Unexpected API response format for group: $group_path"
    log "Response: $response_body"
    return 1
  fi
  
  local project_count=$(echo "$response_body" | jq '. | length')
  log "Found $project_count projects in group: $group_path"
  
  # Process projects
  echo "$response_body" | jq -r '.[] | select(.http_url_to_repo != null) | "\(.path_with_namespace) \(.http_url_to_repo)"' | while read -r repo_path repo_url; do
    if [ -n "$repo_path" ] && [ -n "$repo_url" ]; then
      clone_or_pull "$repo_path" "$repo_url"
    else
      log_warning "Skipping project with incomplete information: $repo_path"
    fi
  done
}

# Function to test GitLab API connectivity and token
test_gitlab_connectivity() {
  local gitlab_url="$1"
  local test_url="$gitlab_url/user"
  
  log "Testing GitLab connectivity for: $gitlab_url (with 30s timeout)"
  
  # Add timeout and better error handling
  local api_response=$(curl -s -w "HTTP_CODE:%{http_code}" \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 1 \
    --header "PRIVATE-TOKEN: $TOKEN" \
    "$test_url" 2>/dev/null)
  
  local http_code=$(echo "$api_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
  local response_body=$(echo "$api_response" | sed 's/HTTP_CODE:[0-9]*$//')
  
  if [ "$http_code" = "200" ]; then
    local username=$(echo "$response_body" | jq -r '.username // "unknown"')
    log_success "GitLab API connectivity test passed for $gitlab_url (user: $username)"
    return 0
  elif [ "$http_code" = "000" ]; then
    log_warning "Connection timeout or network issue for $gitlab_url"
    
    # Extract hostname for network testing
    local hostname=$(echo "$gitlab_url" | sed 's|https\?://||' | sed 's|/.*||')
    test_network_connectivity "$hostname"
    
    return 1
  else
    error "GitLab API connectivity test failed for $gitlab_url (HTTP $http_code)"
    log "Response: $response_body"
    return 1
  fi
}

# Function to test basic network connectivity
test_network_connectivity() {
  local hostname="$1"
  
  log "Testing basic network connectivity to $hostname"
  
  # Test DNS resolution
  if ! nslookup "$hostname" >/dev/null 2>&1; then
    log_warning "DNS resolution failed for $hostname"
    return 1
  fi
  
  # Test basic connectivity (ping with timeout)
  if ping -c 1 -W 5 "$hostname" >/dev/null 2>&1; then
    log_success "Basic network connectivity to $hostname is working"
    return 0
  else
    log_warning "Basic network connectivity to $hostname failed"
    return 1
  fi
}

# Function to show troubleshooting tips
show_troubleshooting_tips() {
  echo ""
  echo "=== TROUBLESHOOTING TIPS ==="
  echo "1. If you're getting HTTP 000 errors, try:"
  echo "   - Use the -s flag to skip connectivity test: $0 -s -g 'your-groups'"
  echo "   - Check if you're behind a corporate firewall/proxy"
  echo "   - Verify your network connection to the GitLab server"
  echo ""
  echo "2. If you're getting authentication errors:"
  echo "   - Make sure your GitLab token has the correct permissions"
  echo "   - Check if the token is expired"
  echo "   - Verify the group paths exist and you have access to them"
  echo ""
  echo "3. For more detailed debugging:"
  echo "   - Use the -d flag for debug mode: $0 -d -g 'your-groups'"
  echo "   - Check the GitLab server status"
  echo "=========================="
  echo ""
}

# Create the local directory if it doesn't exist
mkdir -p "$LOCAL_DIR"

# Check Git credentials
if ! check_git_credentials; then
  fatal_error "Git credentials check failed"
fi

# Loop through each group in the array and process its projects in parallel
for GROUP_PATH in "${GROUPS_ARRAY[@]}"; do
  log "Processing group: $GROUP_PATH"
  
  # Set GitLab API URL dynamically based on the provided group path
  if [[ "$GROUP_PATH" == *"custom"* ]]; then
    GITLAB_URL="https://gitlab.example.com/api/v4"
  else
    GITLAB_URL="https://gitlab.com/api/v4"
  fi
  
  log "Using GitLab URL: $GITLAB_URL"
  
  # Test GitLab API connectivity and token validity (unless skipped)
  if [ "$SKIP_CONNECTIVITY_TEST" = true ]; then
    log_warning "Skipping connectivity test as requested"
    # Start processing from the main group in the background
    get_all_projects_and_subgroups "$GROUP_PATH" "$GITLAB_URL" &
  elif test_gitlab_connectivity "$GITLAB_URL"; then
    # Start processing from the main group in the background
    get_all_projects_and_subgroups "$GROUP_PATH" "$GITLAB_URL" &
  else
    error "Skipping group $GROUP_PATH due to connectivity issues"
  fi
done

# Wait for all background processes to complete
wait

log_success "All repositories have been cloned or updated in $LOCAL_DIR"