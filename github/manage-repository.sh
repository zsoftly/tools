#!/usr/bin/env bash
set -euo pipefail

readonly gh_bin="${GH_BIN:-gh}"

owner=""
repository=""
registry_input=""
registry_path=""
mode="preview"
resume="false"
mode_set="false"
repository_set="false"
registry_set="false"
owner_set="false"

usage() {
  cat <<'EOF'
Usage: github/manage-repository.sh --owner <owner> --registry <path> --repository <name> [--apply [--resume] | --verify]

The default is a read-only plan. --apply creates and hardens a proposed
repository. --apply --resume hardens an already-created proposed repository
after an interrupted run. --verify reads the configured settings only.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

detail() {
  printf '%s\n' "$*" >&2
}

while (($#)); do
  case "$1" in
    --owner)
      (($# >= 2)) || fail "--owner needs an owner name"
      [[ "$owner_set" == "false" ]] || fail "--owner may be specified once"
      [[ -n "$2" ]] || fail "--owner needs an owner name"
      owner="$2"
      owner_set="true"
      shift 2
      ;;
    --repository)
      (($# >= 2)) || fail "--repository needs a registered name"
      [[ "$repository_set" == "false" ]] || fail "--repository may be specified once"
      repository="$2"
      repository_set="true"
      shift 2
      ;;
    --registry)
      (($# >= 2)) || fail "--registry needs a path"
      [[ "$registry_set" == "false" ]] || fail "--registry may be specified once"
      [[ -n "$2" ]] || fail "--registry needs a path"
      registry_input="$2"
      registry_set="true"
      shift 2
      ;;
    --apply)
      [[ "$mode_set" == "false" ]] || fail "choose only one of --apply or --verify"
      mode="apply"
      mode_set="true"
      shift
      ;;
    --verify)
      [[ "$mode_set" == "false" ]] || fail "choose only one of --apply or --verify"
      mode="verify"
      mode_set="true"
      shift
      ;;
    --resume)
      resume="true"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$repository" ]] || fail "--repository is required"
[[ -n "$owner" ]] || fail "--owner is required"
[[ -n "$registry_input" ]] || fail "--registry is required"
[[ "$resume" == "false" || "$mode" == "apply" ]] || fail "--resume requires --apply"
[[ "$owner" =~ ^[A-Za-z0-9._-]+$ && "$owner" != "." && "$owner" != ".." ]] || fail "invalid owner for this local check; allowed: ASCII letters, digits, dot, underscore, hyphen; not . or .."
[[ "$repository" =~ ^[A-Za-z0-9._-]+$ && "$repository" != "." && "$repository" != ".." ]] || fail "invalid repository name for this local check; allowed: ASCII letters, digits, dot, underscore, hyphen; not . or .."
[[ -r "$registry_input" ]] || fail "registry is unavailable: $registry_input"
registry_path="$(cd "$(dirname "$registry_input")" && pwd)/$(basename "$registry_input")"
readonly registry_path

record="$(awk -F '\t' -v target="$repository" '$1 == target { print; exit }' "$registry_path")"
[[ -n "$record" ]] || fail "repository is not registered: $repository"
matches="$(awk -F '\t' -v target="$repository" '$1 == target { count++ } END { print count + 0 }' "$registry_path")"
[[ "$matches" == "1" ]] || fail "repository is registered more than once: $repository"
IFS=$'\t' read -r name visibility profile state purpose <<<"$record"
[[ "$name" == "$repository" && -n "$visibility" && -n "$profile" && -n "$state" && -n "$purpose" ]] || fail "invalid registry row for: $repository"
[[ "$visibility" == "public" || "$visibility" == "private" ]] || fail "invalid visibility for: $repository"
[[ "$state" == "proposed" || "$state" == "existing" ]] || fail "invalid state for: $repository"

full_name="$owner/$name"

print_plan() {
  printf 'Repository: %s\nVisibility: %s\nProfile: %s\nState: %s\nPurpose: %s\n\n' "$full_name" "$visibility" "$profile" "$state" "$purpose"
  printf 'Plan:\n'
  if [[ "$state" == "proposed" ]]; then
    printf '%s\n' '  - Create with a README and no wiki.'
  else
    printf '%s\n' '  - Creation is unavailable because this registry entry is existing.'
  fi
  printf '%s\n' '  - Disable projects and discussions; allow squash merges only; disable auto-merge; delete merged branches.'
  printf '%s\n' '  - Disable Actions until reviewed CI or a scoped publication credential is configured.'
  if [[ "$visibility" == "public" ]]; then
    printf '%s\n' '  - Enable secret scanning, push protection, private vulnerability reporting, immutable releases, and default-branch protection.'
  else
    printf '%s\n' '  - This script always skips private branch protection and private secret-scanning controls.'
    printf '%s\n' '  - Report those unconfigured controls in verification.'
  fi
  printf '%s\n' '  - Read every configured setting back. A mismatch fails the operation.'
  if [[ "$mode" == "preview" ]]; then
    printf '\nRead-only preview. Re-run with --apply only after human review.\n'
  fi
}

api() {
  "$gh_bin" api "$@"
}

url_encode() {
  local LC_ALL=C value="$1" character encoded="" index
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      [a-zA-Z0-9.~_-]) encoded+="$character" ;;
      *) printf -v character '%%%02X' "'$character"; encoded+="$character" ;;
    esac
  done
  printf '%s' "$encoded"
}

default_branch() {
  local branch
  branch="$(api "repos/$full_name" --jq '.default_branch')" || return
  if [[ -z "$branch" || "$branch" == "null" ]]; then
    detail 'GitHub did not return a default branch.'
    return 1
  fi
  printf '%s' "$branch"
}

create_repository() {
  "$gh_bin" repo create "$full_name" "--$visibility" --add-readme --disable-wiki --description "$purpose"
}

configure_common() {
  api --method PATCH "repos/$full_name" --input - <<'JSON' || return
{"has_wiki":false,"has_projects":false,"has_discussions":false,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"allow_auto_merge":false,"delete_branch_on_merge":true}
JSON
  api --method PUT "repos/$full_name/actions/permissions" -F enabled=false || return
}

configure_public() {
  api --method PATCH "repos/$full_name" --input - <<'JSON' || return
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON
  api --method PUT "repos/$full_name/private-vulnerability-reporting" || return
  api --method PUT "repos/$full_name/immutable-releases" || return
}

protect_default_branch() {
  local branch encoded_branch
  branch="$(default_branch)" || return
  encoded_branch="$(url_encode "$branch")"
  api --method PUT "repos/$full_name/branches/$encoded_branch/protection" --input - <<'JSON' || return
{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":false,"required_approving_review_count":0},"restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false,"required_conversation_resolution":true}
JSON
}

verify_common() {
  local observed
  observed="$(api "repos/$full_name" --jq '[.has_wiki,.has_projects,.has_discussions,.allow_squash_merge,.allow_merge_commit,.allow_rebase_merge,.allow_auto_merge,.delete_branch_on_merge] | @json')" || return
  if [[ "$observed" != '[false,false,false,true,false,false,false,true]' ]]; then
    detail "Common settings readback mismatch: $observed"
    return 1
  fi
  observed="$(api "repos/$full_name/actions/permissions" --jq '.enabled')" || return
  if [[ "$observed" != "false" ]]; then
    detail "Actions permissions readback mismatch: $observed"
    return 1
  fi
}

verify_public() {
  local observed
  observed="$(api "repos/$full_name" --jq '[.security_and_analysis.secret_scanning.status,.security_and_analysis.secret_scanning_push_protection.status] | @json')" || return
  if [[ "$observed" != '["enabled","enabled"]' ]]; then
    detail "Public secret protection readback mismatch: $observed"
    return 1
  fi
  observed="$(api "repos/$full_name/private-vulnerability-reporting" --jq '.enabled')" || return
  if [[ "$observed" != "true" ]]; then
    detail "Private vulnerability reporting readback mismatch: $observed"
    return 1
  fi
  observed="$(api "repos/$full_name/immutable-releases" --jq '.enabled')" || return
  if [[ "$observed" != "true" ]]; then
    detail "Immutable releases readback mismatch: $observed"
    return 1
  fi
}

verify_protection() {
  local branch encoded_branch observed
  branch="$(default_branch)" || return
  encoded_branch="$(url_encode "$branch")"
  observed="$(api "repos/$full_name/branches/$encoded_branch/protection" --jq '[.required_status_checks,.enforce_admins.enabled,.required_pull_request_reviews.dismiss_stale_reviews,.required_pull_request_reviews.require_code_owner_reviews,.required_pull_request_reviews.required_approving_review_count,.restrictions,.required_linear_history.enabled,.allow_force_pushes.enabled,.allow_deletions.enabled,.required_conversation_resolution.enabled] | @json')" || return
  if [[ "$observed" != '[null,true,true,false,0,null,true,false,false,true]' ]]; then
    detail "Branch protection readback mismatch: $observed"
    return 1
  fi
}

verify() {
  assert_target || return
  verify_common || return
  if [[ "$visibility" == "public" ]]; then
    verify_public || return
    verify_protection || return
  else
    printf '%s\n' 'Private profile: this script does not configure private branch protection or private secret scanning.'
  fi
  printf 'Verified configured settings for %s.\n' "$full_name"
}

assert_target() {
  local observed expected
  observed="$(api "repos/$full_name" --jq '[.full_name,.visibility,.permissions.admin] | @json')" || return
  expected="[\"$full_name\",\"$visibility\",true]"
  if [[ "$observed" != "$expected" ]]; then
    detail "Repository identity, visibility, or administrator permission mismatch: $observed"
    return 1
  fi
}

assert_created_target() {
  local attempt
  for attempt in 1 2 3 4; do
    if assert_target; then
      return 0
    fi
    if [[ "$attempt" == "4" ]]; then
      return 1
    fi
    printf 'Repository readback is not ready; retrying identity and permission check (%s/4).\n' "$attempt" >&2
    sleep "$attempt"
  done
}

run_step() {
  local label="$1"
  shift
  if ! "$@"; then
    printf 'ERROR: hardening stopped at: %s\n' "$label" >&2
    printf 'Leave %s in place. Do not delete or recreate it. Inspect with:\n' "$full_name" >&2
    printf '  ' >&2
    printf '%q ' "$0" --owner "$owner" --registry "$registry_path" --repository "$repository" --verify >&2
    printf '\n' >&2
    printf 'After review, resume only the hardening steps with:\n' >&2
    printf '  ' >&2
    printf '%q ' "$0" --owner "$owner" --registry "$registry_path" --repository "$repository" --apply --resume >&2
    printf '\n' >&2
    exit 1
  fi
}

run_verification() {
  if ! verify; then
    printf 'ERROR: verification failed for %s.\n' "$full_name" >&2
    exit 1
  fi
}

print_plan

case "$mode" in
  preview)
    exit 0
    ;;
  verify)
    run_verification
    ;;
  apply)
    [[ "$state" == "proposed" ]] || fail "only proposed repositories may be created or resumed"
    if [[ "$resume" == "false" ]]; then
      run_step "repository creation" create_repository
      run_step "repository identity, visibility, and administrator permission check" assert_created_target
    else
      run_step "repository identity, visibility, and administrator permission check" assert_target
    fi
    run_step "common repository settings" configure_common
    if [[ "$visibility" == "public" ]]; then
      run_step "public security and release settings" configure_public
      run_step "default branch protection" protect_default_branch
    else
      printf '%s\n' 'Private profile: this script skips private branch protection and private secret-scanning controls.'
    fi
    run_step "settings readback" verify
    ;;
esac
