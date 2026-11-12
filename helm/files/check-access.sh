#!/bin/sh
# The "helm test" of the database (templates/tests/access-test.yaml): every role of roles.conf logs in with its
# password from the Secret and
#   - reaches its own database, as a plain login (no superuser, CREATEDB or CREATEROLE);
#   - a service's role owns its database; an extra role does not and has no right on it beyond CONNECT;
#   - is refused on every other database of the list, on the maintenance database postgres and on template1, with
#     PostgreSQL's "permission denied for database" (a wrong password or an unreachable server is a failure, not a
#     refusal). The test needs one free connection per role: a role at its CONNECTION LIMIT is refused everywhere
#     before the CONNECT right is checked, and that is reported as such.
# Exits 1 when any check fails. Prints no password.
#
# Environment: PGHOST, PGPORT; ROLES_CONF and SECRETS_DIR (defaults below).
set -eu

conf=${ROLES_CONF:-/etc/postgres-setup/roles.conf}
secrets=${SECRETS_DIR:-/run/secrets/database}
: "${PGHOST:?PGHOST is not set}"
export PGCONNECT_TIMEOUT=5 PGAPPNAME=database-access-test

databases="$(awk '$1 == "owner" { print $2 }' "$conf") postgres template1"
failed=0

fail() {
  echo "FAIL $1"
  failed=1
}

while read -r kind db role key limit; do
  case "$kind" in owner | extra) ;; *) continue ;; esac
  if [ ! -s "$secrets/$key" ]; then
    fail "$role: the Secret has no key $key"
    continue
  fi
  PGPASSWORD=$(cat "$secrets/$key")
  export PGPASSWORD

  # Own database: who am I, what may I do, who owns it.
  if ! out=$(psql -X -w -tA -F ' ' -U "$role" -d "$db" -c "SELECT r.rolsuper OR r.rolcreatedb OR r.rolcreaterole, pg_get_userbyid(d.datdba), has_database_privilege(current_user, current_database(), 'CREATE'), has_database_privilege(current_user, current_database(), 'TEMPORARY') FROM pg_roles r, pg_database d WHERE r.rolname = current_user AND d.datname = current_database()" < /dev/null 2>&1); then
    case "$out" in
      *'too many connections for role'*)
        fail "$role is at its connection limit ($limit): its clients hold every connection, so nothing could be checked; lower the service's pool or raise connectionLimit" ;;
      *) fail "$role cannot connect to its database $db: $out" ;;
    esac
    continue
  fi
  set -- $out
  if [ "$1" != f ]; then fail "$role is more than a plain login (superuser, CREATEDB or CREATEROLE)"; fi
  if [ "$kind" = owner ] && [ "$2" != "$role" ]; then fail "$db is owned by $2, not by $role"; fi
  if [ "$kind" = extra ] && { [ "$2" = "$role" ] || [ "$3" != f ] || [ "$4" != f ]; }; then
    fail "extra role $role has more than CONNECT on $db (owner $2, CREATE $3, TEMPORARY $4)"
  fi

  # Every other database: refused for lack of the CONNECT right.
  refused=0
  for other in $databases; do
    [ "$other" = "$db" ] && continue
    if out=$(psql -X -w -tA -U "$role" -d "$other" -c 'SELECT 1' < /dev/null 2>&1); then
      fail "$role reached the database $other"
    elif printf '%s' "$out" | grep -q 'permission denied for database'; then
      refused=$((refused + 1))
    else
      fail "$role on $other: not a permission refusal: $out"
    fi
  done
  echo "ok $kind $role: own database $db reached, refused on $refused other databases"
done < "$conf"

unset PGPASSWORD
if [ "$failed" -ne 0 ]; then
  echo "access test FAILED"
  exit 1
fi
echo "access test passed"
