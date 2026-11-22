#!/usr/bin/env bash
# The kit in a real sandbox check-docker, with its own mirror sbx-docker-mirror-check on port 29599.
# The single-quoted check commands expand in the sandbox's shell, not here.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
name=check-docker
env_file=$repo/tests/sbxenv.yaml
mirror=$repo/host/sbx-docker-mirror
mirror_name=sbx-docker-mirror-check
port=29599
hook_log=/var/log/sbx-docker.log
log=$(mktemp)
fails=0

owner_state() { docker inspect sbx-docker-mirror 2>&1 || true; }

remove_sandbox() {
  sbx env rm --force --no-input --name "$name" "$env_file" >/dev/null 2>&1 || true
}

cleanup() {
  remove_sandbox
  "$mirror" --name "$mirror_name" --port "$port" purge >/dev/null 2>&1 || true
  rm -f "$log"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }

fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}

# check <what> <command>: the command runs in the sandbox, with $port and $hook_log set
check() {
  local what=$1
  shift
  if sbx exec "$name" sh -c "port=$port; hook_log=$hook_log; $*" >>"$log" 2>&1; then
    pass "$what"
  else
    fail "$what"
  fi
}

# mac <what> <command...>: the command runs on the Mac
mac() {
  local what=$1
  shift
  if "$@" >>"$log" 2>&1; then
    pass "$what"
  else
    fail "$what"
  fi
}

count() { sbx exec "$name" sh -c "grep -c '$1' $hook_log || true" 2>>"$log" | tr -d '[:space:]'; }

owner_before=$(owner_state)

mac "the kit is valid" sbx kit validate "$repo"
if ! "$mirror" --name "$mirror_name" --port "$port" up >>"$log" 2>&1; then
  tail -5 "$log"
  echo "FAIL the check's mirror starts"
  exit 1
fi
# sbx keeps the policy log of a removed sandbox under its name: only blocks after this create count.
since=$(date +%Y-%m-%dT%H:%M:%S)
if ! sbx env create --force --no-input --name "$name" --kit-arg "mirrorPort=$port" "$env_file" >>"$log" 2>&1; then
  tail -20 "$log"
  echo "FAIL create $name"
  exit 1
fi

check "the sandbox runs on the base image" test -f /usr/local/share/sbx-stack/VERSION
check "dockerd uses the mirror" \
  'docker info --format "{{json .RegistryConfig.Mirrors}}" | grep -qF "http://host.docker.internal:$port/"'
check "the hook wrote daemon.json once and reloaded dockerd" \
  '[ "$(grep -c "wrote daemon.json mirror http://host.docker.internal:$port" $hook_log)" -eq 1 ] && grep -q "reloaded dockerd" $hook_log'
check "no disk warning at a normal start" '! grep -q "warn /var/lib/docker" $hook_log'
check "Compose starts a service with a published port" \
  'docker compose up -d --wait && curl -fsS -o /dev/null http://localhost:8080/'
mac "the pull went through the check's mirror" \
  sh -c "curl -fsS http://127.0.0.1:$port/v2/_catalog | grep -q library/nginx"

# The Claude kit's own apt refresh is blocked in every sandbox (plain HTTP); every other blocked host is a finding.
# This runs before the push, which must be blocked.
blocked=$(sbx policy log "$name" --json --limit 0 |
  jq -r --arg since "$since" '[.blocked[]? | select(.last_seen[0:19] >= $since) | .host
    | select(. != "deb.debian.org:80" and . != "dhi.io:80")] | unique | join(" ")')
if [ -z "$blocked" ]; then
  pass "the network policy blocks nothing the kit needs"
else
  fail "the network policy blocks: $blocked"
fi

check "a push to Docker Hub fails at the proxy" \
  'docker tag nginx:1-alpine docker.io/library/check-docker-push:x &&
   ! timeout 120 docker push docker.io/library/check-docker-push:x >/tmp/push.out 2>&1 && grep -q 403 /tmp/push.out'

for round in 1 2 3; do
  unchanged=$(count 'unchanged daemon.json')
  sbx stop "$name" >>"$log" 2>&1
  check "stop and start $round: the mirror is set once, the hook did not write the file again" \
    'docker info --format "{{json .RegistryConfig.Mirrors}}" | grep -qF "http://host.docker.internal:$port/" &&
     [ "$(jq ".\"registry-mirrors\" | length" /etc/docker/daemon.json)" -eq 1 ] &&
     [ "$(grep -c "wrote daemon.json" $hook_log)" -eq 1 ] &&
     [ "$(grep -c "unchanged daemon.json" $hook_log)" -eq '"$((unchanged + 1))"' ]'
done

check "the hook keeps another key of daemon.json" \
  'jq ". + {\"debug\": false}" /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.new >/dev/null &&
   sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json &&
   sudo /usr/local/bin/sbx-docker-setup $port &&
   [ "$(jq .debug /etc/docker/daemon.json)" = false ] &&
   jq -e ".\"registry-mirrors\" == [\"http://host.docker.internal:$port\"]" /etc/docker/daemon.json'
check "an invalid daemon.json is left as is and logged" \
  'sudo cp /etc/docker/daemon.json /tmp/daemon.json.good &&
   echo "{" | sudo tee /etc/docker/daemon.json >/dev/null &&
   sudo /usr/local/bin/sbx-docker-setup $port &&
   [ "$(cat /etc/docker/daemon.json)" = "{" ] && grep -q "invalid daemon.json, left as is" $hook_log
   rc=$?; sudo cp /tmp/daemon.json.good /etc/docker/daemon.json; exit $rc'
check "the hook warns when the disk is fuller than the limit" \
  'sudo /usr/local/bin/sbx-docker-setup $port 0 && grep -q "warn /var/lib/docker" $hook_log'

mac "the check's mirror stops" "$mirror" --name "$mirror_name" --port "$port" down
check "a pull works with the mirror down" 'timeout 180 docker pull -q busybox:1'

if [ "$fails" -ne 0 ]; then
  mkdir -p "$repo/scratchpad"
  cp "$log" "$repo/scratchpad/check.log"
fi

remove_sandbox
"$mirror" --name "$mirror_name" --port "$port" purge >>"$log" 2>&1 || true
mac "no sandbox $name is left" sh -c "! sbx ls 2>/dev/null | grep -qw $name"
mac "no container and no volume $mirror_name is left" \
  sh -c "! docker container inspect $mirror_name >/dev/null 2>&1 && ! docker volume inspect $mirror_name >/dev/null 2>&1"
mac "the owner's mirror is untouched" test "$(owner_state)" = "$owner_before"

[ "$fails" -eq 0 ]
