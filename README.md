# database

The database server of **Chance**: one PostgreSQL 18 server in the cluster with one database and one least-privileged
login role per service (plan DM-01, ADR-029). Each service sees only its own database: the role owns it, and every
right on it (also CONNECT) is revoked from everyone else, so a service's credentials cannot even open another
service's database (requirement 3). There is no code here: the repository is a Helm chart around the official
`postgres` image, a Job that creates the roles and databases, a NetworkPolicy, an access test and the checks that keep
them honest. The local equivalent, with the same names, is `infrastructure/local` (compose file and
`postgres/init/10-create-databases.sql`).

## What this repository holds

| Path | What |
|---|---|
| [`helm/Chart.yaml`](helm/Chart.yaml) | The chart `database` (appVersion = the PostgreSQL version of the image) |
| [`helm/values.yaml`](helm/values.yaml), [`values-dev.yaml`](helm/values-dev.yaml), [`values-prod.yaml`](helm/values-prod.yaml) | The settings, each with its reason in a comment |
| [`helm/values.schema.json`](helm/values.schema.json) | Refuses unknown keys, another Service name or port, an image without a digest, and anything but a key name where a password would go |
| [`helm/templates/statefulset.yaml`](helm/templates/statefulset.yaml), [`services.yaml`](helm/templates/services.yaml) | The server, its client Service `postgres` and its headless Service |
| [`helm/templates/setup-job.yaml`](helm/templates/setup-job.yaml), [`setup-configmap.yaml`](helm/templates/setup-configmap.yaml), [`helm/files/setup-databases.sh`](helm/files/setup-databases.sh) | The roles and databases (a Helm hook after every install and upgrade) |
| [`helm/templates/networkpolicy.yaml`](helm/templates/networkpolicy.yaml) | Who may connect |
| [`helm/templates/tests/access-test.yaml`](helm/templates/tests/access-test.yaml), [`helm/files/check-access.sh`](helm/files/check-access.sh) | The `helm test` access test |
| [`scripts/test-setup.sh`](scripts/test-setup.sh), [`scripts/schema-refusals.sh`](scripts/schema-refusals.sh) | The local and pipeline checks (below) |
| [`.github/`](.github/) | Pipeline (the shared workflow with `build-image: false`, plus the database's own checks), CODEOWNERS, Dependabot |

## What the chart deploys

`helm template` with the prod values renders seven objects: a **StatefulSet** `postgres` with one replica and one
8 GiB PersistentVolumeClaim (`data-postgres-0`), two **Services** (`postgres`, a ClusterIP, and the headless
`postgres-headless` the StatefulSet needs), a ConfigMap `postgres-setup` (the Job's script, the test's script and the
list of roles; no passwords), the setup **Job** (a hook), the **NetworkPolicy** and the access-test Pod (only created
by `helm test`). No Secret (the pipeline creates it), no Ingress, no LoadBalancer, no NodePort, no exporter sidecar.

## The values in plain words

| Value | Setting | Why |
|---|---|---|
| Service name | `postgres`, port 5432 (the schema refuses anything else) | identity's chart fixes `jdbc:postgresql://postgres:5432/keycloak`; every service's `DATABASE_URL` uses the same host |
| Pod label | `app.kubernetes.io/name: postgres` | The egress rules of markets, trading and market-data select the database by exactly this label |
| Replicas | 1 | One small node (ADR-029, ADR-039); a replica would need streaming replication and a second disk |
| Image | `postgres:18.6-alpine` by the digest of its multi-platform index (`sha256:9ba53c7d...085b`, read 2026-11-11) | The tag of the services' compose files; a tag can move, a digest cannot. The Job and the test use the same image |
| Databases and roles | tenants, payments, audit, markets, trading, market_data, keycloak; each role owns its database | The names of the local init script; market-data's are `market_data` |
| Connection limits | 10 per service role, 20 for keycloak, `max_connections` 100 | A bulkhead (DM-01): one leaking pool cannot take the server. Pools are 5 per Pod (`DATABASE_POOL_MAX`): one Pod leaves 5 free, two Pods during a rolling update fill the 10. Keycloak's pool stays at 15 or below (Deploy). A role at its limit is refused on every database, also by the access test, which needs one free connection per role. The templates refuse limits that add up to more than `max_connections` minus 5 |
| Server settings | `shared_buffers` 128MB, `max_wal_size` 512MB | Small node, small disk; WAL cannot fill the volume during a burst |
| Memory | request 384 Mi, limit 768 Mi | Below |
| CPU | request 100m, no limit | As in the service charts: a CPU limit only throttles |
| Disk | 8 GiB on the cluster's default storage class (AKS: Azure Disk CSI, Standard SSD) | Below; the claim is kept when the release is uninstalled |
| Authentication | scram-sha-256 for every TCP login (also from 127.0.0.1), peer on the local socket | Set by `POSTGRES_INITDB_ARGS` when initdb runs on an empty volume |
| Security | runs as the image's `postgres` user (70), group 70, `fsGroup` 70 (changed only when the volume root differs), read-only root file system, writable mounts only for the data, `/var/run/postgresql` and `/tmp`; no capabilities, no privilege escalation, default seccomp profile, no service account token, no Service environment variables | Checked locally with Docker: user 70, read-only root file system, the same writable mounts (Checks). `fsGroup` on an Azure disk has not run yet (below) |
| Shutdown | `preStop: pg_ctl stop --mode=fast --no-wait`, 60 s grace | The image's stop signal is SIGINT, which the container runtime sends and postgres already takes as a fast shutdown; the hook is a second guard in case a runtime sends SIGTERM, a "smart" shutdown that would wait for every pooled connection and end in a SIGKILL and crash recovery. A stop signal during a fast shutdown changes nothing |
| Pod labels | only the selector labels, `part-of` and `managed-by` on the server's Pod template | `helm.sh/chart` and the version label change with every chart bump; on the Pod they would restart the server for a change that only concerns the Job or the test |
| PodDisruptionBudget | none | Below |
| NetworkPolicy | off by default, **on in the prod values** (as the broker) | Below |
| `podAnnotations` | accepted, put on the setup Job's Pod only | The shared workflow passes `podAnnotations.checksum/app-env`; the server reads the Secret only at initdb, so a changed password must not restart it |

### The volume's permissions

With `fsGroup` 70 and `fsGroupChangePolicy: OnRootMismatch` the kubelet changes the volume's group and permissions only
when the volume root does not match yet: on the first mount of a new, empty Azure disk (root-owned, with
`lost+found`). Then initdb creates PGDATA (`/var/lib/postgresql/18/docker`) with 0700. If the root is changed by hand
later, the next mount changes every file recursively and makes PGDATA group-writable, which postgres refuses ("data
directory has invalid permissions"); the image's entrypoint sets PGDATA back to 0700 at every start, before the server
checks it. This path has only been read from the image, not run on an Azure disk: watch the first start's log.

### Why no PodDisruptionBudget

With one replica there are only two budgets: `maxUnavailable: 1`, which lets the one pod be evicted and so protects
nothing, and `minAvailable: 1`, which forbids evicting it, so every node drain and AKS upgrade would hang on the
database until someone deletes the budget. Neither helps. A node drain stops the database for the restart (about
10-30 s); the services' readiness checks report it and they reconnect.

### The NetworkPolicy

Port 5432 only, only from the Pods whose label `app.kubernetes.io/name` is one of `databases[].app` (tenants,
payments, audit, markets, trading, market-data, identity: the chart names, which their charts put on their Pods), and
from this release's setup Job and access test. No other namespace, no gateway, nothing from outside. It needs a network
policy engine: the AKS cluster reports none today (`infrastructure/envs/prod/imports.tf`: "Azure reports none"), so
the rule is in place but not enforced until one is turned on (Follow-ups). The CONNECT rights hold either way.

## The Secret

The chart never creates a Secret and holds only the names of its keys. The pipeline creates `database-env` from the
organization secret **`DATABASE_ENV`** (the shared workflow's `app-env`, server-side apply, values masked in the log).
`DATABASE_ENV` holds one `KEY=value` line per key, each value a long random password:

| Key | Used by |
|---|---|
| `POSTGRES_PASSWORD` | The superuser `postgres`: initdb on an empty volume, and the setup Job's login |
| `TENANTS_DB_PASSWORD`, `PAYMENTS_DB_PASSWORD`, `AUDIT_DB_PASSWORD`, `MARKETS_DB_PASSWORD`, `TRADING_DB_PASSWORD`, `MARKET_DATA_DB_PASSWORD` | The role of each service |
| `KEYCLOAK_DB_PASSWORD` | The role `keycloak` (identity) |
| one `<NAME>_PASSWORD` per extra role, if any | Extra roles (below) |

The same password goes into the service's own Secret (`<service>-env`, its `DATABASE_URL`), so a service never sees
another service's password or the database's Secret:

```
DATABASE_URL=postgres://tenants:<the value of TENANTS_DB_PASSWORD>@postgres:5432/tenants
```

identity uses `KC_DB_USERNAME=keycloak` and `KC_DB_PASSWORD=<the value of KEYCLOAK_DB_PASSWORD>` with its fixed
`KC_DB_URL`. A password with characters such as `@`, `:` or `/` must be percent-encoded in a URL; random letters and
digits avoid that.

## Roles and databases (the setup Job)

After every install and upgrade a Helm hook Job runs [`setup-databases.sh`](helm/files/setup-databases.sh) as the
superuser against `postgres:5432`. It waits up to 2 minutes for the server, then for each line of `roles.conf` (rendered
from `databases` in the values):

- creates the role if it is missing, and on every run sets its password from the Secret, its connection limit and
  `NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`;
- creates the database if it is missing with the service's role as owner, sets the owner again and runs
  `REVOKE ALL ON DATABASE ... FROM PUBLIC` (also on the maintenance database `postgres` and on `template1`);
- grants an extra role `CONNECT` on its service's database, nothing else.

It never drops anything; a service removed from the values keeps its role and database until someone drops them by
hand. Passwords go to psql through the environment (`\getenv`), never on a command line; errors are terse and the
session turns statement logging off, so no password reaches a log. The last Job stays in the namespace until the next
deploy so its log can be read; when it fails, the deploy fails and the pipeline rolls back.

### Extra login roles

A service can get further login roles next to its owner role, for example trading's runtime role that may only
`INSERT` and `SELECT` on `ledger_events` while the owner role runs the migrations (ADR-056). In the values:

```yaml
  - name: trading
    role: trading
    ...
    extraRoles:
      - name: trading_app
        passwordKey: TRADING_APP_DB_PASSWORD
        connectionLimit: 10
```

The Job creates `trading_app` as a plain login with its password from the Secret and grants it `CONNECT` on `trading`
only. It owns nothing and gets no other right: trading's own migrations (run as `trading`, the owner) grant it what it
needs, for example `GRANT USAGE ON SCHEMA ...` and `GRANT SELECT, INSERT ON ... ledger_events`, and set default
privileges for new tenant schemas. Add the key to `DATABASE_ENV` before the deploy. Empty by default.

### Add a service

Add an entry to `databases` (name, role, key, the label of its Pods, limit), add its key to `DATABASE_ENV`, deploy.
The access test checks the new role at once.

## Memory and disk

The node (Standard_DS2_v2, 7 GiB, about 5.3 GiB for Pods, `observability/README.md`) has 1 680 Mi requested by the
services and the broker and 512 Mi set aside for PostgreSQL and Traefik together. PostgreSQL asks for **384 Mi**:
`shared_buffers` 128 MB plus a few MB per connection; with about 40 open connections (seven pools of up to 5 and
Keycloak) it stays near 300-400 MB. The request is that working set: under memory pressure the kubelet evicts first
the Pods that use more than they asked for, and evicting the database would stop every service and Keycloak. It
leaves 128 Mi of the 512 Mi for Traefik. The **768 Mi** limit covers 80 connections; above it the kernel stops the
server, and the StatefulSet restarts it with crash recovery. At M1 the real use is measured (ADR-039) and the request
moved. No PriorityClass: none of the charts has one, and it is a cluster-wide object (a follow-up if evictions show).

**Disk: 8 GiB.** Seven small databases (Keycloak's realm is tens of MB; the ledger, audit log and price history grow
by kilobytes per trade), WAL capped at 512 MB, room to grow. Azure bills a Standard SSD by size tier, and 8 GiB is one
of the smallest.

## Rotate a password

- **A service's role:** put the new value into `DATABASE_ENV` and into the service's own Secret (its `DATABASE_URL`),
  then deploy the database (the Job applies it) and then the service. Between the two deploys new connections of that
  service fail; already open ones keep working.
- **The superuser:** the Job logs in with the password in the Secret, so change the server first, then the Secret:
  `kubectl exec -it -n prod postgres-0 -- psql -U postgres -c '\password postgres'` (peer login on the socket; it
  prompts twice for the new value). The `-it` is needed: without a terminal psql reads two empty answers and
  **clears** the superuser's password, with exit code 0 (tried on the pinned image). Then check the new value over
  TCP before touching the Secret: `kubectl exec -it -n prod postgres-0 -- psql -h 127.0.0.1 -U postgres -c 'SELECT 1'`
  asks for the password and must print 1. Only then put the same value into `DATABASE_ENV` and deploy.

## Resize the volume

A StatefulSet's claim template cannot change in place, so a bigger disk is three steps (the default storage class
allows expansion):

1. `kubectl patch pvc data-postgres-0 -n prod -p '{"spec":{"resources":{"requests":{"storage":"16Gi"}}}}'` and wait
   until `kubectl get pvc data-postgres-0 -n prod` shows the new size (an Azure disk may need the Pod restarted).
2. `kubectl delete statefulset postgres -n prod --cascade=orphan` (removes only the StatefulSet object; the Pod and
   the data keep running).
3. Set `persistence.size: 16Gi` in `values.yaml` and deploy; Helm creates the StatefulSet again with the new template.

A disk can grow, never shrink.

## Backups (follow-up)

Not built yet. The data lives on one Azure disk; losing it loses every service's data. The cheapest next steps, none
trivial enough to add without a decision: a CSI `VolumeSnapshot` of `data-postgres-0` on a schedule (Azure snapshots
are billed per GiB used), or a nightly `pg_dumpall` CronJob to Azure Blob Storage (needs a storage account and its
credential in a Secret). Either needs a restore drill before it counts.

## Deploy

The organization's workflow deploys the chart like a service, with `build-image: false` and the release name
`database` in the namespace `prod`. Before the first deploy:

1. Create the organization secret `DATABASE_ENV` with every key of "The Secret", and add the repository to the
   secret's allowed repositories.
2. Push `org-github` first (the input `build-image` exists only there), then create the GitHub repository `database`.
3. Deploy the database **before** identity and the services: their migrations need their database.
4. Each service's Secret gets its `DATABASE_URL` with host `postgres` and its own password; identity gets
   `KC_DB_USERNAME=keycloak` and `KC_DB_PASSWORD`.
5. Set identity's Keycloak pool to 15 or less (`KC_DB_POOL_MAX_SIZE`; Keycloak's default is 100), below the role's
   limit of 20, so the access test, an admin session and a second Keycloak Pod during a rollout still get a connection.

## Checks

Run locally on 2026-11-11 (Helm v4.3.1, kubeconform for Kubernetes 1.35.0, Docker); the pipeline runs the same:

| Check | Command | Result |
|---|---|---|
| Lint | `helm lint helm --namespace prod --strict [-f helm/values-dev.yaml / -f helm/values-prod.yaml]` | 0 failed (default, dev, prod) |
| Kubernetes schemas | `helm template database helm --namespace prod -f helm/values-<dev/prod>.yaml \| kubeconform -strict -summary -kubernetes-version 1.35.0` | dev 6 valid, prod 7 valid |
| Schema refusals | `scripts/schema-refusals.sh` | 20 cases as expected |
| Setup Job and access test | `scripts/test-setup.sh` | Passed: first run creates 8 roles and 7 databases; second run creates nothing; every role reaches its own database and is refused on the 8 others (the other service databases, `postgres`, `template1`); a rotated password fails before the next run, works after it, and the old one is refused; fast stop (the preStop command, then the image's SIGINT) exit 0, restart on the same data |

`scripts/test-setup.sh` takes the image, the server arguments and `POSTGRES_INITDB_ARGS` from the rendered
StatefulSet and the scripts from the rendered ConfigMap, and runs the server as user 70 on a read-only root file system
with the same writable mounts as the chart; passwords are random per run and deleted with the containers. It uses a
Docker volume, so `fsGroup` and the first mount of an Azure disk are not part of it ("The volume's permissions").

## Update the image

Take the new tag the services' compose files use, read its index digest (`docker buildx imagetools inspect
postgres:<tag>`), set `image.tag` and `image.digest`, bump the chart version, run `scripts/test-setup.sh`. A new major
version needs `pg_upgrade` or a dump and restore: never just a new tag.

## Follow-ups

1. Backups (above).
2. A network policy engine on the AKS cluster, so the NetworkPolicy is enforced (the broker and the service charts
   wait for the same).
3. A metrics exporter for the monitoring namespace (connections per role, database sizes), if the dashboards need it.
4. A managed Azure Database for PostgreSQL (ADR-029: B1ms, 50 connections) would change only the Secrets and the host;
   the setup Job's script works against it as it is (its admin is not a superuser, so `NOBYPASSRLS` and similar may need
   adjusting).
