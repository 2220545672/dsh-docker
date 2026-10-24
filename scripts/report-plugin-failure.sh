#!/usr/bin/env bash
#
# Report a dsh-context-editor compatibility failure to the plugin repository.
#
#   scripts/report-plugin-failure.sh <plugin-version> <dsh-version> [image]
#
# The plugin is the subject under test, so its issues belong in
# 2220545672/dsh-context-editor. This repository's own GITHUB_TOKEN cannot open
# an issue there, so the report travels as a `repository_dispatch` event and the
# plugin repository's workflow files the issue with its own token.
#
# Environment:
#   CROSS_REPO_TOKEN  token allowed to dispatch events to the plugin repository
#                     (fine-grained: Contents read and write on that repository;
#                     classic: `repo`). When unset, the failure is logged and an
#                     issue is opened in *this* repository instead, so a missing
#                     secret can never hide a red run.
#   GH_TOKEN          this repository's token, used only for the fallback issue
#   GITHUB_REPOSITORY this repository (owner/name), for the fallback issue
#   GITHUB_RUN_ID     run id, used to build the run link
#   GITHUB_SERVER_URL server base, default https://github.com
set -Eeuo pipefail

PLUGIN_VERSION="${1:?usage: report-plugin-failure.sh <plugin-version> <dsh-version> [image]}"
DSH_VERSION="${2:-unknown}"
IMAGE="${3:-}"
PLUGIN_REPO="${PLUGIN_REPO:-2220545672/dsh-context-editor}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
RUN_URL=""
if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    RUN_URL="${SERVER}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

printf 'reporting plugin compatibility failure: %s@%s (DSH %s)\n' \
    "${PLUGIN_REPO}" "${PLUGIN_VERSION}" "${DSH_VERSION}"

# JSON payload for the dispatch. jq is on every GitHub runner and is used rather
# than string interpolation so a version or URL can never break the body.
payload="$(jq -n \
    --arg plugin_version "${PLUGIN_VERSION}" \
    --arg dsh_version "${DSH_VERSION}" \
    --arg image "${IMAGE}" \
    --arg run_url "${RUN_URL}" \
    '{event_type: "plugin-compat-failed",
      client_payload: {
        plugin_version: $plugin_version,
        dsh_version: $dsh_version,
        image: $image,
        run_url: $run_url
      }}')"

if [[ -n "${CROSS_REPO_TOKEN:-}" ]]; then
    code="$(curl --silent --output "${TMPDIR:-/tmp}/dispatch-body.json" --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer ${CROSS_REPO_TOKEN}" \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --data "${payload}" \
        "https://api.github.com/repos/${PLUGIN_REPO}/dispatches" || true)"
    if [[ "${code}" == "204" ]]; then
        printf 'ok   dispatched plugin-compat-failed to %s\n' "${PLUGIN_REPO}"
        exit 0
    fi
    printf 'warning: dispatch to %s returned %s\n' "${PLUGIN_REPO}" "${code}" >&2
    cat "${TMPDIR:-/tmp}/dispatch-body.json" >&2 || true
    printf '\n' >&2
else
    printf 'warning: CROSS_REPO_TOKEN is not set; falling back to an issue in this repository\n' >&2
fi

# Fallback: an issue here, clearly labelled, so the failure is still visible.
if [[ -z "${GH_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
    printf 'cannot file a fallback issue (GH_TOKEN or GITHUB_REPOSITORY missing)\n' >&2
    exit 1
fi

title="[plugin-compat] dsh-context-editor@${PLUGIN_VERSION} failed against ${DSH_VERSION} (fallback)"
body="$(mktemp)"
{
    echo 'The cross-repository compatibility test failed and the report could not'
    echo "be forwarded to \`2220545672/dsh-context-editor\`."
    echo
    echo "- plugin: \`dsh-context-editor@${PLUGIN_VERSION}\`"
    echo "- DSH: \`${DSH_VERSION}\`"
    [[ -n "${IMAGE}" ]] && echo "- image: \`${IMAGE}\`"
    [[ -n "${RUN_URL}" ]] && echo "- failing run: ${RUN_URL}"
    echo
    echo 'Fix the forwarding so this class of failure lands in the plugin repository:'
    echo "add a \`CROSS_REPO_TOKEN\` secret to this repository (see CONTRIBUTING.md)."
} > "${body}"

existing="$(gh issue list --repo "${GITHUB_REPOSITORY}" --state open --search 'plugin-compat in:title' \
    --json number,title \
    | jq -r --arg title "${title}" '.[] | select(.title == $title) | .number' | head -n1)"
if [[ -n "${existing}" ]]; then
    gh issue comment "${existing}" --repo "${GITHUB_REPOSITORY}" --body-file "${body}"
    printf 'commented on fallback issue #%s\n' "${existing}"
else
    url="$(gh issue create --repo "${GITHUB_REPOSITORY}" --title "${title}" --body-file "${body}")"
    printf 'opened fallback issue %s\n' "${url}"
fi
