#!/usr/bin/env bash
# The host script on the Mac only: its own mirror sbx-docker-mirror-test on port 29598, removed at the end.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
mirror=$repo/host/sbx-docker-mirror
name=sbx-docker-mirror-test
port=29598
other_port=29597
log=$(mktemp)
fails=0
nc_pid=

cleanup() {
  if [ -n "$nc_pid" ]; then kill "$nc_pid" 2>/dev/null || true; fi
  "$mirror" --name "$name" --port "$port" purge >/dev/null 2>&1 || true
  rm -f "$log"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }

fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}

# expect <what> <exit code> <text in the output, or ''> <command...>
expect() {
  local what=$1 code=$2 text=$3 out rc=0
  shift 3
  out=$("$@" 2>&1) || rc=$?
  printf '$ %s\n%s\n[rc=%s]\n' "$*" "$out" "$rc" >>"$log"
  if [ "$rc" -eq "$code" ] && { [ -z "$text" ] || grep -qF -- "$text" <<<"$out"; }; then
    pass "$what"
  else
    fail "$what"
  fi
}

# assert <what> <command...>
assert() {
  local what=$1
  shift
  if "$@" >>"$log" 2>&1; then
    pass "$what"
  else
    fail "$what"
  fi
}

m() { "$mirror" --name "$name" --port "$port" "$@"; }
cid() { docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true; }
volume_created() { docker volume inspect -f '{{.CreatedAt}}' "$name" 2>/dev/null || true; }
owner_state() { docker inspect sbx-docker-mirror 2>&1 || true; }
has() { grep -qF -- "$2" <<<"$1"; }
matches() { grep -Eq -- "$2" <<<"$1"; }

wait_listen() {

  for _ in $(seq 1 25); do
    if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  return 1
}

owner_before=$(owner_state)

expect "no argument: usage" 2 '' "$mirror"
expect "an unknown command: usage" 2 '' "$mirror" bogus
expect "port 80: usage" 2 '' "$mirror" --port 80 up
expect "a name with a space: usage" 2 '' "$mirror" --name 'a b' up
expect "no Docker: one clear line" 1 'Docker does not run on this Mac' \
  env DOCKER_HOST=unix:///nonexistent "$mirror" --name "$name" --port "$port" up

expect "up starts the mirror" 0 "running $name on 127.0.0.1:$port" m up
assert "the mirror answers /v2/" curl -fsS -o /dev/null "http://127.0.0.1:$port/v2/"
assert "the restart policy is unless-stopped" \
  test "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name")" = unless-stopped
assert "the port is bound to 127.0.0.1 only" \
  test "$(docker inspect -f '{{range (index .HostConfig.PortBindings "5000/tcp")}}{{.HostIp}} {{end}}' "$name")" = "127.0.0.1 "
assert "the mirror pulls from Docker Hub" \
  has "$(docker inspect -f '{{json .Config.Env}}' "$name")" REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io

id=$(cid)
expect "up again succeeds" 0 "running $name on 127.0.0.1:$port" m up
assert "up again keeps the container" test -n "$id" -a "$(cid)" = "$id"
expect "up with another port fails" 1 'run down first' "$mirror" --name "$name" --port "$other_port" up
assert "up with another port keeps the container" test -n "$id" -a "$(cid)" = "$id"
expect "status shows the running mirror" 0 "$name: running 127.0.0.1:$port" m status
assert "status shows the cache size" matches "$(m status)" "^$name: running 127\.0\.0\.1:$port, cache [0-9.]+[kMG]?B$"

volume=$(volume_created)
docker stop "$name" >>"$log" 2>&1 || true
expect "up after docker stop runs the mirror again" 0 "running $name on 127.0.0.1:$port" m up
assert "the stopped mirror comes back on the same volume" test -n "$volume" -a "$(volume_created)" = "$volume"

expect "down succeeds" 0 '' m down
assert "down removes the container" test -z "$(cid)"
assert "down keeps the volume" test "$(volume_created)" = "$volume"
expect "status after down says absent" 0 "$name: absent" m status

nc -l 127.0.0.1 "$port" >/dev/null 2>&1 &
nc_pid=$!
assert "a test listener holds the port" wait_listen "$port"
expect "up on a held port fails" 1 "port $port is in use by another process" m up
assert "up on a held port starts no container" test -z "$(cid)"
kill "$nc_pid" 2>/dev/null || true
wait "$nc_pid" 2>/dev/null || true
nc_pid=

expect "purge succeeds" 0 '' m purge
assert "purge removes the volume" test -z "$(volume_created)"
expect "purge with nothing left succeeds" 0 '' m purge
assert "the owner's mirror is untouched" test "$(owner_state)" = "$owner_before"

if [ "$fails" -ne 0 ]; then
  mkdir -p "$repo/scratchpad"
  cp "$log" "$repo/scratchpad/mirror.log"
fi

[ "$fails" -eq 0 ]
