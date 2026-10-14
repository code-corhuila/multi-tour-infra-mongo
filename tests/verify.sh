#!/bin/sh
# The V checks of the spec (RN-INF-11 to RN-INF-16) against a throwaway instance. CI and a developer
# run this same file; Docker is the only requirement.
#
# It never touches dev, qa or main: it starts the project multi-tour-ci from a variables file built
# in a temporary directory with passwords generated now, so no secret is written in the repository.
# Removing a volume is allowed only for that throwaway project (Annex J, J.5.4).
set -u
cd "$(dirname "$0")/.." || exit 1

# Git Bash on Windows rewrites container paths such as /docker-entrypoint-initdb.d; no effect elsewhere
export MSYS_NO_PATHCONV=1

PROJECT="multi-tour-ci"
TMP=$(mktemp -d) || exit 1
ENVF="$TMP/ci.env"
# the native docker client needs a Windows path for the file; elsewhere cygpath does not exist
ENVF_ARG="$ENVF"
command -v cygpath >/dev/null 2>&1 && ENVF_ARG=$(cygpath -m "$ENVF")
BASE=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
fail=0

# One distinct password per user from a random base that lives only in this process
password() { printf '%s-%s' "$BASE" "$1"; }

# -p wins over the file, so no variable can make this script address another environment
dc() { docker compose -p "$PROJECT" --env-file "$ENVF_ARG" "$@"; }

cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

build_env() {
  src=env/dev.env.example
  if [ ! -f "$src" ]; then : > "$ENVF"; return 0; fi
  while IFS= read -r line; do
    case $line in
      \#*) printf '%s\n' "$line" ;;
      COMPOSE_PROJECT_NAME=*) printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT" ;;
      MONGO_INITDB_ROOT_PASSWORD=*) printf 'MONGO_INITDB_ROOT_PASSWORD=%s\n' "$(password admin)" ;;
      IDENTITY_AUDIT_APP_PASSWORD=*) printf 'IDENTITY_AUDIT_APP_PASSWORD=%s\n' "$(password identity_audit)" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$src" > "$ENVF"
}

value() { sed -n "s/^$1=//p" "$ENVF" | head -1; }
mongo_admin() { dc exec -T mongo mongosh --quiet -u "$ADMIN" -p "$(password admin)" --authenticationDatabase admin --eval "$1"; }
mongo_app() { dc exec -T mongo mongosh --quiet -u identity_audit_app -p "$(password identity_audit)" --authenticationDatabase identity_audit --eval "$1"; }

run() { # name, function
  if reason=$("$2" 2>&1); then
    echo "PASS  $1"
  else
    echo "FAIL  $1"
    [ -n "$reason" ] && printf '%s\n' "$reason" | sed 's/^/        /'
    fail=1
  fi
}

V_no_real_env_file_versioned() {
  # tracked files plus untracked ones that git would not ignore, i.e. what a commit could take
  listed=$(git ls-files --cached --others --exclude-standard | grep -E '(^|/)\.env$|^env/[^/]+\.env$')
  [ -z "$listed" ] || { echo "a real variables file is versionable: $listed"; return 1; }
  [ "$(git check-ignore env/dev.env)" = "env/dev.env" ] || { echo "env/dev.env is not ignored"; return 1; }
  [ -z "$(git check-ignore env/dev.env.example)" ] || { echo "env/dev.env.example is ignored but must be versioned"; return 1; }
  # compose.yml may name a variable, never carry a literal password
  grep -E '^[[:space:]]*(MONGO_INITDB_ROOT_PASSWORD|IDENTITY_AUDIT_APP_PASSWORD):' compose.yml | grep -vq '\${' && { echo "compose.yml carries a literal password"; return 1; }
  return 0
}

V_one_mongo_container_per_environment() {
  services=$(dc config --services 2>&1) || { echo "docker compose config failed: compose.yml is missing or invalid"; return 1; }
  [ "$services" = "mongo" ] || { echo "services are '$(echo $services)', expected exactly 'mongo'"; return 1; }
  images=$(dc config --images 2>/dev/null)
  printf '%s\n' "$images" | grep -Eq '^mongo:8\.0\.[0-9]+$' || { echo "image '$images' is not pinned to an exact 8.0 version"; return 1; }
  # the resolved file holds the passwords, so it is only searched, never printed
  dc config 2>/dev/null | grep -Eq '^[[:space:]]+ports:' && { echo "the resolved configuration publishes ports"; return 1; }
  [ "$STARTED" = 1 ] || { echo "the instance did not start healthy"; return 1; }
  ids=$(dc ps -q)
  [ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ] || { echo "expected exactly one container"; return 1; }
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$ids")" = healthy ] || { echo "the container is not healthy"; return 1; }
}

V_replica_set_is_primary() {
  primaries=$(mongo_admin "rs.status().members.filter(m => m.stateStr === 'PRIMARY').length" 2>&1) || { echo "rs.status() failed: $primaries"; return 1; }
  [ "$primaries" = 1 ] || { echo "expected one PRIMARY member, got '$primaries'"; return 1; }
}

V_init_runs_only_on_empty_volume() {
  mongo_admin "db.getSiblingDB('verify').marker.insertOne({v: 'kept'})" >/dev/null || { echo "could not write the marker document"; return 1; }
  dc restart mongo >/dev/null 2>&1
  dc up -d --wait --wait-timeout 120 mongo >/dev/null 2>&1 || { echo "the instance did not come back healthy"; return 1; }
  [ "$(mongo_admin "db.getSiblingDB('verify').marker.countDocuments({v: 'kept'})")" = 1 ] || { echo "the marker document is gone after the restart"; return 1; }
  # the image logs this line only while it runs the init scripts of an empty volume, once per start
  [ "$(dc logs mongo 2>&1 | grep -c 'running /docker-entrypoint-initdb.d/01-instance.js')" = 1 ] || { echo "the init script did not run exactly once across the restart"; return 1; }
}

V_app_user_reaches_only_its_database() {
  [ "$(mongo_app "db.getSiblingDB('identity_audit').probe.insertOne({v: 1}).acknowledged")" = true ] || { echo "identity_audit_app cannot write in identity_audit"; return 1; }
  mongo_app "db.getSiblingDB('other_domain').probe.insertOne({v: 1})" >/dev/null 2>&1 && { echo "identity_audit_app wrote in another database"; return 1; }
  dc exec -T mongo mongosh --quiet -u identity_audit_app -p "wrong-$BASE" --authenticationDatabase identity_audit --eval "db.runCommand({ping: 1})" >/dev/null 2>&1 && { echo "identity_audit_app accepted a wrong password"; return 1; }
  return 0
}

snapshot() { # the user with its credentials, so a reset password shows as a difference
  mongo_admin "JSON.stringify(db.getSiblingDB('identity_audit').getUsers({showCredentials: true}))"
}

V_init_runs_twice_without_error() {
  snapshot > "$TMP/before.txt" || { echo "could not read the users"; return 1; }
  out=$(dc exec -T -e IDENTITY_AUDIT_APP_PASSWORD="$(password identity_audit)" mongo mongosh --quiet -u "$ADMIN" -p "$(password admin)" --authenticationDatabase admin /docker-entrypoint-initdb.d/01-instance.js 2>&1) || { echo "the second run failed:"; printf '%s\n' "$out" | tail -n 5; return 1; }
  snapshot > "$TMP/after.txt" || { echo "could not read the users"; return 1; }
  cmp -s "$TMP/before.txt" "$TMP/after.txt" || { echo "the second run changed the users"; return 1; }
}

# ---- setup: a clean throwaway project, then one instance
build_env
dc down -v --remove-orphans >/dev/null 2>&1 || true
docker network inspect platform >/dev/null 2>&1 || docker network create platform >/dev/null
ADMIN=$(value MONGO_INITDB_ROOT_USERNAME)
STARTED=0
dc up -d --wait --wait-timeout 120 mongo >"$TMP/up.log" 2>&1 && STARTED=1

run "V·one_mongo_container_per_environment" V_one_mongo_container_per_environment
run "V·replica_set_is_primary" V_replica_set_is_primary
run "V·init_runs_only_on_empty_volume" V_init_runs_only_on_empty_volume
run "V·no_real_env_file_versioned" V_no_real_env_file_versioned
run "V·app_user_reaches_only_its_database" V_app_user_reaches_only_its_database
run "V·init_runs_twice_without_error" V_init_runs_twice_without_error

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
