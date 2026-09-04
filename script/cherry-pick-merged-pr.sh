#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./script/cherry-pick-merged-pr.sh <pr-number> [<pr-number> ...]

Examples:
  ./script/cherry-pick-merged-pr.sh 175907
  ./script/cherry-pick-merged-pr.sh 175907 179766

Environment:
  TARGET_BRANCH   Branch to cherry-pick onto (default: custom/main)
  SEARCH_REFS     Space-separated refs to search for merged commits
                  (default: "origin/master origin/dev")
  NO_FETCH=1      Skip "git fetch origin --tags --prune"
  APPLY=0         Only resolve and print commit hashes, do not cherry-pick

Notes:
  - PR commit discovery looks for subjects containing "(#<pr-number>)".
  - Commits are cherry-picked with -x for provenance.
  - Husky hooks are disabled for cherry-pick in this helper (HUSKY=0).
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_branch="${TARGET_BRANCH:-custom/main}"
search_refs="${SEARCH_REFS:-origin/master origin/dev}"
apply_changes="${APPLY:-1}"

if [[ "${NO_FETCH:-0}" != "1" ]]; then
  git -C "${repo_path}" fetch origin --tags --prune
fi

if ! git -C "${repo_path}" rev-parse --verify "${target_branch}" >/dev/null 2>&1; then
  echo "Target branch not found: ${target_branch}" >&2
  exit 1
fi

if [[ -n "$(git -C "${repo_path}" status --porcelain)" ]]; then
  echo "Repo has uncommitted changes: ${repo_path}" >&2
  echo "Commit/stash/discard first, then retry." >&2
  exit 1
fi

current_branch="$(git -C "${repo_path}" rev-parse --abbrev-ref HEAD)"
if [[ "${current_branch}" != "${target_branch}" ]]; then
  git -C "${repo_path}" checkout "${target_branch}" >/dev/null
fi

normalize_pr() {
  local raw="$1"
  raw="${raw#\#}"
  if [[ ! "${raw}" =~ ^[0-9]+$ ]]; then
    echo "Invalid PR number: $1" >&2
    return 1
  fi
  echo "${raw}"
}

find_pr_commit() {
  local pr="$1"
  local line
  line="$(git -C "${repo_path}" --no-pager log \
    --format='%H%x09%s' \
    --grep="(\#${pr})" \
    ${search_refs} 2>/dev/null | head -n 1 || true)"

  if [[ -z "${line}" ]]; then
    return 1
  fi

  printf '%s\n' "${line}"
}

for raw_pr in "$@"; do
  pr="$(normalize_pr "${raw_pr}")"

  if ! match_line="$(find_pr_commit "${pr}")"; then
    echo "PR #${pr}: not found in search refs (${search_refs})" >&2
    exit 1
  fi

  commit_hash="${match_line%%$'\t'*}"
  commit_subject="${match_line#*$'\t'}"

  echo "PR #${pr} -> ${commit_hash} ${commit_subject}"

  if git -C "${repo_path}" merge-base --is-ancestor "${commit_hash}" HEAD; then
    echo "  already present on ${target_branch}, skipping"
    continue
  fi

  if [[ "${apply_changes}" == "0" ]]; then
    echo "  dry-run: would cherry-pick -x ${commit_hash}"
    continue
  fi

  if HUSKY=0 git -C "${repo_path}" cherry-pick -x "${commit_hash}"; then
    echo "  cherry-pick applied"
  else
    if git -C "${repo_path}" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1 && \
      [[ -z "$(git -C "${repo_path}" ls-files -u)" ]] && \
      git -C "${repo_path}" diff --quiet && \
      git -C "${repo_path}" diff --cached --quiet; then
      git -C "${repo_path}" cherry-pick --skip
      echo "  equivalent patch already present, skipped"
      continue
    fi

    echo "Cherry-pick stopped on PR #${pr}. Resolve conflicts, then run:" >&2
    echo "  cd ${repo_path}" >&2
    echo "  HUSKY=0 git cherry-pick --continue" >&2
    echo "Or abort with:" >&2
    echo "  git cherry-pick --abort" >&2
    exit 1
  fi
done

echo "Done. Current HEAD: $(git -C "${repo_path}" rev-parse --short HEAD) on ${target_branch}"