#!/bin/bash
set -euo pipefail

PGBIN=/usr/lib/postgresql/15/bin
PGDATA=/app/pgdata
PGPORT=5432

if [ "${DROP_NET_RAW:-1}" = "1" ] \
    && [ "${_ARTEX_LEASH_NET_RAW_DROPPED:-0}" != "1" ] \
    && command -v capsh >/dev/null 2>&1; then
    export _ARTEX_LEASH_NET_RAW_DROPPED=1
    exec capsh --drop=cap_net_raw -- "$0" "$@"
fi

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo "[artex-leash] POSTGRES_PASSWORD is required" >&2
    exit 1
fi
if [ ! -x "$PGBIN/initdb" ]; then
    echo "[artex-leash] PostgreSQL binaries not found at $PGBIN" >&2
    exit 1
fi

run_as_postgres() {
    setpriv --reuid=postgres --regid=postgres --init-groups -- "$@"
}

mkdir -p "$PGDATA" /app/data /app/keys /var/run/postgresql
chown -R postgres:postgres "$PGDATA"
chown postgres:postgres /var/run/postgresql
chmod 0700 /app/keys 2>/dev/null || true

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[artex-leash] initializing embedded PostgreSQL in $PGDATA"
    pwfile=$(mktemp)
    rm -f "$pwfile"
    run_as_postgres sh -c 'umask 077; printf "%s\n" "$POSTGRES_PASSWORD" > "$1"' sh "$pwfile"
    run_as_postgres "$PGBIN/initdb" \
        -D "$PGDATA" \
        -U artex \
        --pwfile="$pwfile" \
        --auth-local=trust \
        --auth-host=scram-sha-256
    rm -f "$pwfile"
    {
        echo "listen_addresses = '127.0.0.1'"
        echo "port = $PGPORT"
        echo "unix_socket_directories = '/var/run/postgresql'"
    } >>"$PGDATA/postgresql.conf"
fi

echo "[artex-leash] starting embedded PostgreSQL"
run_as_postgres "$PGBIN/pg_ctl" \
    -D "$PGDATA" \
    -l "$PGDATA/postgres.log" \
    -o "-c listen_addresses=127.0.0.1 -p $PGPORT" \
    -w start

if ! run_as_postgres "$PGBIN/psql" -U artex -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='artex'" | grep -q 1; then
    echo "[artex-leash] creating artex database"
    run_as_postgres "$PGBIN/createdb" -U artex artex
fi

pw_sql=${POSTGRES_PASSWORD//\'/\'\'}
run_as_postgres "$PGBIN/psql" -U artex -d postgres -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE artex WITH PASSWORD '$pw_sql'" >/dev/null

if [ -z "${ARTEX_PG_DSN:-}" ]; then
    encoded_pw=$(python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["POSTGRES_PASSWORD"], safe=""))')
    export ARTEX_PG_DSN="postgres://artex:${encoded_pw}@127.0.0.1:${PGPORT}/artex?sslmode=disable"
fi
export ARTEX_JWT_KEY_DIR=/app/keys

echo "[artex-leash] starting Artex"
/app/start.sh "$@" &
app_pid=$!
stopping=0

forward() {
    stopping=1
    kill -TERM "$app_pid" 2>/dev/null || true
}
trap forward TERM INT

set +e
wait "$app_pid"
status=$?
set -e

if [ "$stopping" -eq 1 ]; then
    wait "$app_pid" 2>/dev/null || true
    status=0
fi

echo "[artex-leash] stopping embedded PostgreSQL"
run_as_postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop || true

exit "$status"
