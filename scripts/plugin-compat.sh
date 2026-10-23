#!/usr/bin/env bash
#
# Cross-repository compatibility smoke for the dsh-context-editor plugin.
#
#   scripts/plugin-compat.sh <dsh-version> <plugin-version>
#
# Installs the exact DSH version and the published plugin into a throwaway
# DSH_HOME, boots the web server, and asserts that the plugin is present in the
# live client bundle graph. This runs on the CI runner (Node/npm only), not in
# the image, so it can gate a plugin release before the image is rebuilt.
set -Eeuo pipefail

DSH_VERSION="${1:?usage: plugin-compat.sh <dsh-version> <plugin-version>}"
PLUGIN_VERSION="${2:?usage: plugin-compat.sh <dsh-version> <plugin-version>}"
PORT="${PLUGIN_COMPAT_PORT:-$((18090 + RANDOM % 1000))}"
TMP="$(mktemp -d)"
PID=""

cleanup() {
    if [[ -n "${PID}" ]]; then
        kill "${PID}" >/dev/null 2>&1 || true
        wait "${PID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP}"
}
trap cleanup EXIT

export DSH_HOME="${TMP}/home"
export npm_config_cache="${TMP}/npm-cache"
mkdir -p "${DSH_HOME}" "${npm_config_cache}"

printf 'installing @deepseek-ai/dsh@%s\n' "${DSH_VERSION}"
if ! npm install --prefix "${TMP}/tool" --no-save --no-package-lock \
    "@deepseek-ai/dsh@${DSH_VERSION}" >"${TMP}/dsh-install.log" 2>&1; then
    cat "${TMP}/dsh-install.log"
    exit 1
fi
DSH="${TMP}/tool/node_modules/.bin/dsh"
[[ -x "${DSH}" ]] || { echo 'dsh executable is missing after install' >&2; exit 1; }

printf 'installing dsh-context-editor@%s into the test profile\n' "${PLUGIN_VERSION}"
if ! "${DSH}" plugin --profile web add "dsh-context-editor@${PLUGIN_VERSION}" >"${TMP}/plugin-install.log" 2>&1; then
    cat "${TMP}/plugin-install.log"
    exit 1
fi

printf 'booting dsh web on 127.0.0.1:%s\n' "${PORT}"
"${DSH}" web --no-open --port "${PORT}" --host 127.0.0.1 >"${TMP}/web.log" 2>&1 &
PID=$!

ready=0
for _ in $(seq 1 90); do
    if ! kill -0 "${PID}" >/dev/null 2>&1; then
        printf 'dsh web exited during startup\n' >&2
        cat "${TMP}/web.log"
        exit 1
    fi
    body="$(curl --silent --show-error --max-time 3 \
        "http://127.0.0.1:${PORT}/plugins/events" 2>/dev/null || true)"
    if grep --quiet 'dsh-context-editor' <<<"${body}"; then
        ready=1
        break
    fi
    sleep 2
done

if [[ "${ready}" != "1" ]]; then
    printf 'dsh-context-editor never appeared in /plugins/events\n' >&2
    cat "${TMP}/web.log"
    exit 1
fi

# The UI gate answers 401 when no credentials are supplied; this proves the
# server is actually serving the application, not just the events endpoint.
code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PORT}/" || true)"
if [[ "${code}" != "401" ]]; then
    printf 'expected unauthenticated / to be 401, got %s\n' "${code}" >&2
    cat "${TMP}/web.log"
    exit 1
fi

printf 'ok: dsh-context-editor@%s is active on DSH %s\n' "${PLUGIN_VERSION}" "${DSH_VERSION}"
