#!/usr/bin/env bash
#
# Copyright Red Hat
#
# This script is invoked from .github/workflow/envoy-sync-receive.yaml workflow.
#
# It merges the specified branch from the upstream envoyproxy/envoy
# repository into the current branch in the current working directory.
# It is assumed that the envoy-sync-receive.yaml workflow has already
# checked out the destination repository and switched to the destination
# branch, in the current working directory before invoking us.
#
# - If the merge is successful, it:
#  - pushes the feature branch to the fork
#  - creates the associated pull request if it doesn't already exist
#  - closes the associated issue if it already exists
# -If the merge is unsuccessful, it:
#  - leaves the associated pull request untouched if it already exists
#  - creates the associated issue issue if it doesn't already exist
#  - adds a comment on the associated issue to describe the merge fail
#

set -xeuo pipefail

notice() { printf "::notice:: %s\n" "$1"; }

SCRATCH="$(mktemp -d)"
cleanup() {
    local savexit=$?
    rm -rf -- "${SCRATCH}"
    exit "${savexit}"
}
trap 'cleanup' EXIT

SRC_REPO_URL="https://github.com/envoyproxy/envoy.git"
SRC_REPO_PATH="${SRC_REPO_URL/#*github.com?/}"
SRC_REPO_PATH="${SRC_REPO_PATH/%.git/}"
SRC_BRANCH_NAME="$1"
SRC_HEAD_SHA="$(git ls-remote "${SRC_REPO_URL}" | awk "/\srefs\/heads\/${SRC_BRANCH_NAME/\//\\\/}$/{print \$1}")"

DST_REPO_URL=$(git remote get-url origin)
DST_REPO_PATH="${DST_REPO_URL/#*github.com?/}"
DST_REPO_PATH="${DST_REPO_PATH/%.git/}"
DST_BRANCH_NAME=$(git branch --show-current)
DST_HEAD_SHA=$(git rev-parse HEAD)

# Add the remote upstream repo and fetch the specified branch
git remote remove upstream &> /dev/null || true
git remote add -f -t "${SRC_BRANCH_NAME}" upstream "${SRC_REPO_URL}"

# Compose text for pull request or issue title
TITLE="auto-merge ${SRC_REPO_PATH}[${SRC_BRANCH_NAME}] "
TITLE+="into ${DST_REPO_PATH}[${DST_BRANCH_NAME}]"

# Create a new branch name for the merge. Deliberately don't include
# any commit hash or timestamp in the name to ensure it is repeatable.
# This ensures that each time we get invoked, due to an upstream change,
# we accumulate the changes in the same branch and pull request, rather
# than creating new ones that superceed the old one(s) each time.
DST_NEW_BRANCH_NAME="auto-merge-$(echo "${SRC_BRANCH_NAME}" | tr /. -)"

# Set the default remote for the gh command
gh repo set-default "${DST_REPO_PATH}"

# Ensure the merge commit message lists all the merged commits (defaults to 20)
git config set --local merge.log 100000

# Perform the merge using --no-ff option to force creating a merge commit
if git merge --no-ff -m "${TITLE}" --log "upstream/${SRC_BRANCH_NAME}" > "${SCRATCH}/mergeout"; then
    DST_NEW_HEAD_SHA="$(git rev-parse HEAD)"
    if [[ "${DST_NEW_HEAD_SHA}" != "${DST_HEAD_SHA}" ]]; then
        git push --force origin "HEAD:${DST_NEW_BRANCH_NAME}"
        PR_COUNT=$(gh pr list --head "${DST_NEW_BRANCH_NAME}" \
                              --base "${DST_BRANCH_NAME}" \
                              --state open | wc -l)
        if [[ ${PR_COUNT} == 0 ]]; then
            PR_URL=$(gh pr create --head "${DST_NEW_BRANCH_NAME}" \
                                  --base "${DST_BRANCH_NAME}" \
                                  --title "${TITLE}" \
                                  --body "Generated by $(basename "$0")")
            MERGE_OUTCOME="Created ${PR_URL}"
        else
            PR_ID=$(gh pr list --head "${DST_NEW_BRANCH_NAME}" \
                               --base "${DST_BRANCH_NAME}" \
                               --state open | head -1 | cut -f1)
            PR_URL="https://github.com/${DST_REPO_PATH}/pull/${PR_ID}"
            MERGE_OUTCOME="Updated ${PR_URL}"
        fi
    else
        MERGE_OUTCOME="No changes"
    fi
    notice "${TITLE} successful (${MERGE_OUTCOME})"
    # Close any related issues with a comment describing why
    for ISSUE_ID in $(gh issue list -S "${TITLE} failed" | cut -f1); do
        ISSUE_URL="https://github.com/${DST_REPO_PATH}/issues/${ISSUE_ID}"
        gh issue close "${ISSUE_URL}" --comment "Successful ${TITLE} (${MERGE_OUTCOME})"
        notice "Closed ${ISSUE_URL}"
    done
else # merge fail
    notice "${TITLE} failed"
    ISSUE_COUNT=$(gh issue list -S "${TITLE} failed" | wc -l)
    if [[ ${ISSUE_COUNT} == 0 ]]; then
        ISSUE_URL=$(gh issue create --title "${TITLE} failed" --body "${TITLE} failed")
        ISSUE_ID="$(basename "${ISSUE_URL}")"
        ISSUE_OUTCOME="Created"
    else
        ISSUE_ID="$(gh issue list -S "${TITLE} failed sort:created-asc" | tail -1 | cut -f1)"
        ISSUE_URL="https://github.com/${DST_REPO_PATH}/issues/${ISSUE_ID}"
        ISSUE_OUTCOME="Updated"
    fi
    COMMENT_URL=$(\
        gh issue comment "${ISSUE_URL}" --body-file - <<-EOF
			Failed to ${TITLE}
			
			Upstream   : [${SRC_HEAD_SHA}](https://github.com/${SRC_REPO_PATH}/commit/${SRC_HEAD_SHA})
			Downstream : [${DST_HEAD_SHA}](https://github.com/${DST_REPO_PATH}/commit/${DST_HEAD_SHA})
			
			\`\`\`
			$(cat "${SCRATCH}/mergeout" || true)
			\`\`\`
		EOF
    )
    notice "${ISSUE_OUTCOME} ISSUE#${ISSUE_ID} (${COMMENT_URL})"
    exit 1
fi
