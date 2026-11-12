#!/usr/bin/env bash
# Runs the chart's own setup Job script and access test against a throwaway PostgreSQL container, the way the cluster
# runs them: the image, the server arguments and POSTGRES_INITDB_ARGS are taken from the rendered StatefulSet, the
# scripts and roles.conf from the rendered ConfigMap (scripts/test-values.yaml: the prod values plus one extra role).
# The server runs as user 70 on a read-only root file system with writable mounts only for its data, its socket
# directory and /tmp, as in the chart. Checks:
#   1. setup run twice: the second run creates nothing and fails nothing (idempotent);
#   2. the access test: each role reaches its own database and is refused on every other one;
#   3. a rotated password: the test fails with the new password before the next run, passes after it, and the old
#      password is refused;
#   4. a fast stop (the preStop command, then the image's stop signal) and a restart on the same data, then the
#      access test again.
# Passwords are random per run, live in a temporary folder and are deleted with the containers at the end.
#
# Needs helm, docker and python3 with PyYAML. Usage: scripts/test-setup.sh (CPUS=0.5 by default per container).
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
name=${NAME:-database-setup-test}
cpus=${CPUS:-0.5}
work=$(mktemp -d)

cleanup() {
  docker rm -f "$name" "$name-run" > /dev/null 2>&1 || true
  docker volume rm -f "$name-data" > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# The containers run as user 70 and read the mounted files.
chmod 0755 "$work"

step() { printf '\n== %s\n' "$1"; }

step "render the chart and take out the Job's files"
helm template database "$here/helm" --namespace prod -f "$here/helm/values-prod.yaml" -f "$here/scripts/test-values.yaml" > "$work/render.yaml"
python3 -I "$here/scripts/extract_render.py" "$work/render.yaml" "$work"
image=$(cat "$work/image")
mapfile -t args < "$work/args"
initdb_args=$(cat "$work/initdb-args")
conf="$work/setup/roles.conf"
grep -v '^#' "$conf"

step "random passwords for the superuser and every role"
new_password() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n'; }
mkdir -m 0755 "$work/secrets"
for key in POSTGRES_PASSWORD $(awk '$1 == "owner" || $1 == "extra" { print $4 }' "$conf"); do
  new_password > "$work/secrets/$key"
done
chmod 0444 "$work/secrets"/*
ls "$work/secrets"

step "start the server (user 70, read-only root file system, the chart's arguments)"
docker run -d --name "$name" --cpus "$cpus" --user 70:70 --read-only \
  --tmpfs /var/run/postgresql:uid=70,gid=70,mode=0775 --tmpfs /tmp:uid=70,gid=70,mode=1777 \
  -v "$name-data:/var/lib/postgresql" -v "$work/secrets:/run/secrets/database:ro" \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD_FILE=/run/secrets/database/POSTGRES_PASSWORD \
  -e POSTGRES_INITDB_ARGS="$initdb_args" \
  "$image" "${args[@]}" > /dev/null
wait_ready() {
  for _ in $(seq 90); do
    if docker exec "$name" pg_isready -q -h 127.0.0.1 -p 5432; then return 0; fi
    sleep 1
  done
  docker logs --tail 30 "$name"
  return 1
}
wait_ready
docker exec "$name" psql -X -tA -U postgres -c 'SELECT version()'

# Runs one of the Job's files in a second container that shares the server's network (127.0.0.1 is the server).
run_job_file() {
  local secrets_dir=$2
  docker run --rm --name "$name-run" --cpus "$cpus" --user 70:70 --read-only --tmpfs /tmp:uid=70,gid=70,mode=1777 \
    --network "container:$name" -v "$work/setup:/etc/postgres-setup:ro" -v "$secrets_dir:/run/secrets/database:ro" \
    -e PGHOST=127.0.0.1 -e PGPORT=5432 -e SUPERUSER=postgres -e SUPERUSER_PASSWORD_KEY=POSTGRES_PASSWORD -e HOME=/tmp \
    "$image" sh "/etc/postgres-setup/$1"
}
inventory() {
  docker exec "$name" psql -X -tA -U postgres -c "SELECT string_agg(rolname || '/' || rolconnlimit, ' ' ORDER BY rolname) FROM pg_roles WHERE rolcanlogin AND rolname <> 'postgres'" \
    -c "SELECT string_agg(datname || ':' || pg_get_userbyid(datdba) || ':' || coalesce(datacl::text, '-'), ' ' ORDER BY datname) FROM pg_database WHERE NOT datistemplate"
}

step "setup, first run"
run_job_file setup-databases.sh "$work/secrets"
inventory | tee "$work/inventory-1"

step "setup, second run (must create nothing)"
run_job_file setup-databases.sh "$work/secrets" | tee "$work/run-2"
inventory | tee "$work/inventory-2"
if grep -q 'created' "$work/run-2"; then echo "FAIL: the second run created something"; exit 1; fi
cmp -s <(sed 's/{[^}]*}//g' "$work/inventory-1") <(sed 's/{[^}]*}//g' "$work/inventory-2") || { echo "FAIL: roles or databases differ after the second run"; exit 1; }
echo "second run: nothing created, same roles, owners and databases"

step "access test"
run_job_file check-access.sh "$work/secrets"

step "rotate the password of the first service role"
read -r _ _ role key _ < <(awk '$1 == "owner" { print; exit }' "$conf")
cp -a "$work/secrets" "$work/old-secrets"
chmod 0644 "$work/secrets/$key"
new_password > "$work/secrets/$key"
echo "role $role, key $key: new value in the Secret, not yet applied"
if run_job_file check-access.sh "$work/secrets" > "$work/before" 2>&1; then echo "FAIL: the new password worked before the setup ran"; exit 1; fi
grep -E "^FAIL $role " "$work/before" | sed -E 's/(password authentication failed for user "[a-z_]+").*/\1/'
step "setup, third run (applies the new password)"
run_job_file setup-databases.sh "$work/secrets" | grep -E "role $role |^done"
run_job_file check-access.sh "$work/secrets" | grep -E "ok owner $role:|passed|FAIL"
if run_job_file check-access.sh "$work/old-secrets" > "$work/old" 2>&1; then echo "FAIL: the old password still works"; exit 1; fi
grep -q "password authentication failed for user \"$role\"" "$work/old" && echo "old password of $role refused: password authentication failed"
[[ "$(grep -c '^FAIL' "$work/old")" == "1" ]] || { echo "FAIL: other roles failed with the old Secret copy"; cat "$work/old"; exit 1; }

step "fast stop (the preStop command), restart on the same data"
# Exactly the chart's preStop command, then the image's stop signal (SIGINT, a fast shutdown itself), which the
# container runtime sends after the hook; during a fast shutdown it changes nothing.
docker image inspect --format 'stop signal of the image: {{.Config.StopSignal}}' "$image"
docker exec "$name" pg_ctl stop --mode=fast --no-wait
docker kill --signal "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" "$name" > /dev/null 2>&1 || true
echo "server exit code after the fast stop: $(docker wait "$name") (0 = clean shutdown)"
docker logs --tail 3 "$name" 2>&1 | grep -E 'shut down|shutting down' || true
docker start "$name" > /dev/null
wait_ready
docker logs --tail 5 "$name" 2>&1 | grep -E 'ready to accept|skipping initialization' || true
run_job_file check-access.sh "$work/secrets" | tail -n 1

printf '\nall checks passed\n'
