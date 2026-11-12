#!/bin/sh
# Creates the login role and the database of every service named in roles.conf, after every install and upgrade
# (Helm hook Job, templates/setup-job.yaml). Idempotent: it creates only what is missing and never drops anything.
# On every run it
#   - sets each role's password from the Secret (a rotated password is applied by the next deploy), its CONNECTION
#     LIMIT and the attributes of a plain login (no superuser, no CREATEDB, no CREATEROLE, no replication, no RLS bypass);
#   - makes each service's role the owner of its database and revokes every right on it from PUBLIC, so no other
#     role can even connect (the same for the maintenance database postgres and for template1, where PUBLIC
#     otherwise keeps CONNECT and TEMPORARY; CREATE DATABASE copies template1 without connecting to it);
#   - grants an extra role of a service CONNECT on that service's database and nothing else (the service's own
#     migrations grant the rest).
# Passwords are read from the files of the mounted Secret and handed to psql through the environment (\getenv), so
# they never appear in a command line, a log line or an error message (terse errors, no statement logging).
#
# Environment: PGHOST, PGPORT, SUPERUSER, SUPERUSER_PASSWORD_KEY; ROLES_CONF and SECRETS_DIR (defaults below).
set -eu

conf=${ROLES_CONF:-/etc/postgres-setup/roles.conf}
secrets=${SECRETS_DIR:-/run/secrets/database}
: "${PGHOST:?PGHOST is not set}" "${SUPERUSER:?SUPERUSER is not set}" "${SUPERUSER_PASSWORD_KEY:?SUPERUSER_PASSWORD_KEY is not set}"
export PGUSER="$SUPERUSER" PGDATABASE=postgres PGCONNECT_TIMEOUT=5 PGAPPNAME=database-setup

read_secret() {
  if [ ! -s "$secrets/$1" ]; then
    echo "the Secret has no key $1 (or it is empty): add it to DATABASE_ENV" >&2
    exit 1
  fi
  cat "$secrets/$1"
}

PGPASSWORD=$(read_secret "$SUPERUSER_PASSWORD_KEY")
export PGPASSWORD

# The server may still be starting (first install: initdb). Up to 2 minutes.
tries=0
until pg_isready -q; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "the server at $PGHOST:${PGPORT:-5432} is not ready after 2 minutes" >&2
    exit 1
  fi
  sleep 2
done

# SQL comes from the here-document on standard input; errors are terse (no statement text, no context).
run_sql() {
  psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse -v SHOW_CONTEXT=never "$@"
}

# Every role first (owners and extra roles), so a database can name its owner.
while read -r kind db role key limit; do
  case "$kind" in owner | extra) ;; *) continue ;; esac
  ROLE_PASSWORD=$(read_secret "$key")
  export ROLE_PASSWORD
  run_sql -v role="$role" -v lim="$limit" << 'SQL'
\set VERBOSITY terse
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') AS role_exists \gset
\if :role_exists
\echo role :role exists: password, limit and attributes set again
\else
CREATE ROLE :"role" LOGIN;
\echo role :role created
\endif
\getenv pw ROLE_PASSWORD
ALTER ROLE :"role" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT :lim PASSWORD :'pw';
\unset pw
SQL
  unset ROLE_PASSWORD
done < "$conf"

# Then the databases, each owned by its service's role and closed to PUBLIC.
while read -r kind db role key limit; do
  [ "$kind" = owner ] || continue
  run_sql -v db="$db" -v role="$role" << 'SQL'
\set VERBOSITY terse
SELECT EXISTS (SELECT FROM pg_database WHERE datname = :'db') AS db_exists \gset
\if :db_exists
\echo database :db exists: owner and rights set again
\else
CREATE DATABASE :"db" OWNER :"role";
\echo database :db created
\endif
ALTER DATABASE :"db" OWNER TO :"role";
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
SQL
done < "$conf"

# Extra roles: CONNECT on their service's database, nothing else.
while read -r kind db role key limit; do
  [ "$kind" = extra ] || continue
  run_sql -v db="$db" -v role="$role" << 'SQL'
\set VERBOSITY terse
GRANT CONNECT ON DATABASE :"db" TO :"role";
\echo extra role :role may connect to :db
SQL
done < "$conf"

# The maintenance database and template1 are closed to the service roles too (template0 takes no connections).
run_sql << 'SQL'
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE template1 FROM PUBLIC;
SQL

echo "done: every role and database of roles.conf is in place"
