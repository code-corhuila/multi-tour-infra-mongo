# multi-tour-infra-mongo

> Single MongoDB instance of the project (container and volume)

Part of the **Multi Tour** distributed system — team `multi-tour`, Grupo 2.
Governance and documentation live in [`multi-tour-docs`](https://github.com/code-corhuila/multi-tour-docs).

## What it is

The single MongoDB instance of the platform (Annex J, Annex B): one container and its volumes per
environment, a single-node replica set with authentication, and the connection user
`identity_audit_app`, with `readWrite` on the `identity_audit` database only. It is **not** where
collections, validators, indexes or migrations live: `multi-tour-identity-audit-db` owns them and
runs its own migrations against this instance. It publishes no port; only the gateway does.

## How to start it

Needs Docker with Compose v2. Pick the environment: `dev`, `qa` or `main`.

```sh
cp env/dev.env.example env/dev.env   # never versioned; fill every secret
sh scripts/up.sh dev                 # creates the network platform and waits until healthy
sh scripts/down.sh dev               # stops it and keeps the data
```

Each environment has its own `COMPOSE_PROJECT_NAME` (`multi-tour-dev`, `-qa`, `-main`), the same
as `multi-tour-infra-postgres`, so each one gets its own container and volumes. The root
composition in `multi-tour-infra-postgres` includes this `compose.yml` with the same variables file.

- In `qa` and `main`, never run `docker compose down -v` or delete the volume, and back up
  before migrating (J.5.4). `scripts/down.sh` refuses `-v`.
- When a domain is added, add its user to `mongo/init/01-instance.js` and run the script again by
  hand (J.5.5); it keeps existing users and their passwords:
  `docker compose --env-file env/dev.env exec mongo mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p --authenticationDatabase admin /docker-entrypoint-initdb.d/01-instance.js`

## Where the data is

Database `identity_audit`, in the volume `mongo-data` of the environment; the replica-set key is in
the volume `mongo-keys`, generated on the first start and never versioned. The administrator is
`MONGO_INITDB_ROOT_USERNAME`; the application user is `identity_audit_app`, with the password
`IDENTITY_AUDIT_APP_PASSWORD` of the environment file. There is no published port; open `mongosh`
inside the container:

```sh
docker compose --env-file env/dev.env exec mongo mongosh -u multitour_admin -p --authenticationDatabase admin
```

## How to test it

```sh
sh tests/verify.sh
```

Needs Docker. It starts a throw-away project, runs the six checks of the spec (one container per
environment, the replica set is primary, the init script only on an empty volume, no real `.env`
versioned, the application user reaches only its database, the init script twice without changes)
and removes it. The CI runs the same script on every pull request to `develop` and `qa`.

## What is missing

The backup and restore of the instance (AC4 of `code-corhuila/multi-tour-docs#200`), which comes
with the story spec.

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `multi-tour-docs`.
