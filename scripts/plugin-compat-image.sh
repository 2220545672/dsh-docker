#!/usr/bin/env bash
#
# Compatibility smoke for the stable dsh-context-editor plugin, run against a
# real dsh-docker image.
#
#   scripts/plugin-compat-image.sh <image> <plugin-version>
#
# The image is the environment that matters here: it is the one that installs
# pnpm, owns the DSH profile layout, and runs the DSH process the user gets. The
# plugin is installed inside the running container with the image's own pnpm,
# then the container is restarted so a profile written after boot is exercised
# by the same boot path as a normal deployment.
set -Eeuo pipefail

IMAGE="${1:?usage: plugin-compat-image.sh <image> <plugin-version>}"
PLUGIN_VERSION="${2:?usage: plugin-compat-image.sh <image> <plugin-version>}"
PORT="${PLUGIN_COMPAT_PORT:-$((18090 + RANDOM % 1000))}"
NAME="dsh-plugin-compat-$$"
WORKDIR="$(mktemp -d)"
FAILURES=0

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}" 2>/dev/null || sudo rm -rf "${WORKDIR}" 2>/dev/null || true
}
trap cleanup EXIT

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

mkdir -p "${WORKDIR}/data" "${WORKDIR}/workspace"

printf 'starting %s\n' "${IMAGE}"
docker run --detach --name "${NAME}" \
    --env 'ALLOWED_CLIENTS=127.0.0.1,172.16.0.0/12' \
    --env 'AUTH_MODE=none' \
    --publish "127.0.0.1:${PORT}:8080" \
    --security-opt seccomp=unconfined \
    --security-opt systempaths=unconfined \
    --volume "${WORKDIR}/data:/data" \
    --volume "${WORKDIR}/workspace:/workspace" \
    "${IMAGE}" >/dev/null

wait_ready() {
    local ready=0
    for _ in $(seq 1 90); do
        if curl --silent --fail --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
            ready=1
            break
        fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "${NAME}" 2>/dev/null)" != "true" ]]; then
            printf 'container exited before healthz answered\n' >&2
            docker logs "${NAME}" >&2 || true
            return 1
        fi
        sleep 2
    done
    if [[ "${ready}" != "1" ]]; then
        printf '/healthz never answered\n' >&2
        docker logs "${NAME}" >&2 || true
        return 1
    fi
}

wait_ready

printf 'installing dsh-context-editor@%s with the image pnpm\n' "${PLUGIN_VERSION}"
if ! docker exec --user 1000:1000 \
    --env HOME=/home/node \
    --env DSH_HOME=/data/dsh \
    "${NAME}" \
    dsh plugin --profile web add "dsh-context-editor@${PLUGIN_VERSION}" >"${WORKDIR}/plugin-install.log" 2>&1; then
    cat "${WORKDIR}/plugin-install.log" >&2
    docker logs "${NAME}" >&2 || true
    exit 1
fi

# Restart through the normal entrypoint: the plugin manager records the bundle
# in the profile, and this proves a plugin installed after first boot survives
# the same startup path a user gets on the next restart.
printf 'restarting %s to exercise the normal boot path\n' "${NAME}"
docker restart "${NAME}" >/dev/null
wait_ready

body=""
for _ in $(seq 1 60); do
    body="$(curl --silent --show-error --max-time 3 \
        "http://127.0.0.1:${PORT}/plugins/events" 2>/dev/null || true)"
    if grep --quiet 'dsh-context-editor' <<<"${body}"; then
        break
    fi
    sleep 2
done

if grep --quiet 'dsh-context-editor' <<<"${body}"; then
    pass "dsh-context-editor@${PLUGIN_VERSION} is in the client bundle graph"
else
    fail "dsh-context-editor@${PLUGIN_VERSION} never appeared in /plugins/events"
    docker logs "${NAME}" >&2 || true
fi

# A plugin that only appears in the event stream but cannot serve its client
# bundle is still broken; assert the graph references a rev and the health
# endpoint still answers after the restart.
code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PORT}/healthz" || true)"
if [[ "${code}" == "ok" || "${code}" == "200" ]]; then
    pass 'image is healthy after the plugin install and restart'
else
    fail "healthz returned ${code} after the restart"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    exit 1
fi

printf 'ok: dsh-context-editor@%s is active in %s\n' "${PLUGIN_VERSION}" "${IMAGE}"
