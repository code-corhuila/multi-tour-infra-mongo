#!/bin/sh
# Creates the replica-set key on the first start, inside its own volume, and reuses it afterwards.
# A replica set with authentication needs a key shared by its members; it is never versioned.
set -eu
key=/keys/replica.key
if [ ! -s "$key" ]; then
  head -c 756 /dev/urandom | base64 | tr -d '\n' > "$key"
fi
chown mongodb:mongodb "$key"
chmod 400 "$key"
exec docker-entrypoint.sh "$@"
