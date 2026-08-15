#!/bin/sh
set -eu

if [ "${AUTO_MIGRATE:-true}" = "true" ]; then
  attempts=0

  until mix ecto.create 2>&1 && mix ecto.migrate; do
    attempts=$((attempts + 1))

    if [ "$attempts" -ge "${DB_STARTUP_RETRIES:-30}" ]; then
      echo "Database setup failed after ${attempts} attempts" >&2
      exit 1
    fi

    echo "Database is not ready; retrying in ${DB_STARTUP_DELAY:-2}s" >&2
    sleep "${DB_STARTUP_DELAY:-2}"
  done
fi

exec "$@"
