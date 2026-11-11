# Xolo Helm chart

Deploys [Xolo](https://github.com/xolo-gateway/xolo), an enterprise LLM
gateway, as a Deployment backed by PostgreSQL.

Every replica serves the web UI, the OpenAI-compatible API (`/api/v1`) and,
when enabled, the provisionning API and the webhook worker. The replicas
share nothing but the database, so you scale out with `replicaCount` or
`autoscaling`, within the connection budget of PostgreSQL.

## Requirements

- Kubernetes 1.29 or later.
- PostgreSQL 15 or later, reachable from the pods. The chart does not deploy
  it. Use a managed instance or an operator such as CloudNativePG. SQLite
  works for a single-replica trial only (`persistence.enabled`).
- Xolo 0.95.0 or later. The chart deploys the version of its `appVersion` by
  default.
- metrics-server, for `autoscaling.enabled`.

## Install

```bash
kubectl create secret generic xolo-db \
  --from-literal=dsn='postgres://xolo:secret@postgres:5432/xolo?sslmode=require'

helm install xolo ./charts/xolo \
  --set baseURL=https://xolo.example.com \
  --set database.existingSecret=xolo-db \
  --set config.XOLO_HTTP_AUTHN_DEFAULT_ADMINS=admin@example.com \
  --set ingress.enabled=true --set 'ingress.hosts[0].host=xolo.example.com'
```

On the first install, the chart generates `XOLO_SECRET_KEY`, which encrypts
the providers' API keys in the database, and `XOLO_HTTP_SESSION_KEYS`, which
sign the session cookies. Later upgrades keep them, and the Secret that holds
them survives an uninstall. Back up `XOLO_SECRET_KEY`: without it, the
provider keys stored in the database cannot be read. The install notes print
the command that reads it. To manage both keys yourself, put them in a Secret
and set `secrets.existingSecret`.

## Main values

| Value | Default | Description |
|---|---|---|
| `baseURL` | `http://localhost:3002` | public URL of the instance, used for links, redirects and OIDC callbacks |
| `database.dsn` | | PostgreSQL connection string |
| `database.existingSecret` | | Secret holding the connection string, instead of `database.dsn` |
| `database.pool.maxOpenConns` | `20` | connections opened by each replica |
| `secrets.existingSecret` | | Secret with `XOLO_SECRET_KEY` and `XOLO_HTTP_SESSION_KEYS` |
| `config` | | `XOLO_*` settings, rendered into a ConfigMap |
| `extraEnv`, `extraEnvFrom` | | further environment, for settings that are secrets (OIDC client secret) |
| `replicaCount` | `2` | number of replicas, without autoscaling |
| `autoscaling.enabled` | `false` | HorizontalPodAutoscaler on CPU, 2 to 10 replicas |
| `ingress.enabled` | `false` | Ingress |
| `httpRoute.enabled` | `false` | Gateway API HTTPRoute, instead of the Ingress |
| `provisionningAPI.enabled` | `false` | machine-to-machine API on its own Service, with mutual TLS |
| `metrics.serviceMonitor.enabled` | `false` | Prometheus Operator ServiceMonitor |
| `plugins.cache.existingClaim` | | volume shared by the replicas for downloaded plugin data |
| `persistence.enabled` | `false` | SQLite on a volume, for a single-replica trial |
| `resources` | 500m CPU, 384 MiB requested | no CPU limit by default (see [Sizing](#sizing)) |

`values.yaml` documents every value.

## Behaviour

**Probes.** Startup and liveness probes call `/healthz`. The readiness probe
calls `/readyz`, which checks the database. The startup probe allows 5
minutes for the schema migrations: one replica runs them under a database
lock while the others wait.

**Rollouts.** The rolling update never removes a replica before its
replacement is ready. A replica asked to stop waits 5 seconds
(`preStopDelaySeconds`), so that every Service and ingress stops sending it
requests, then gives the requests in flight 60 seconds to finish
(`shutdownTimeout`). A rollout or a scale-down does not cut streamed
completions shorter than that.

**Disruptions.** A PodDisruptionBudget allows one replica down at a time.
The replicas spread over nodes and zones when the scheduler can.

**Security.** The pods run as a non-root user with a read-only root
filesystem, no capabilities, the `RuntimeDefault` seccomp profile and no
service account token. `/tmp` and the plugin cache are `emptyDir` volumes.

**Configuration checks.** Rendering fails on a configuration that cannot
work: no database, SQLite without persistence or with more than one replica,
the provisionning API without TLS or authorized client URIs, a ServiceMonitor
without a token.

**Provisionning API.** It has its own Service, never exposed by the Ingress
or the HTTPRoute. The chart mounts its TLS Secret, and Xolo checks the client
certificates against `provisionningAPI.authorizedURIs`.

**Metrics.** `/metrics/` requires the API token of a platform administrator.
The ServiceMonitor reads it from a Secret (`metrics.serviceMonitor.tokenSecret`).

## Streaming behind a proxy

Xolo streams completions as Server-Sent Events. The proxy in front of it must
not buffer responses, and must let a response last as long as the longest
generation. With ingress-nginx:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-body-size: 64m
```

With the Gateway API, `httpRoute.timeouts.request` sets that duration.

Set `config.XOLO_HTTP_RATE_LIMIT_TRUSTED_PROXIES` to the addresses of the
ingress controller pods. Xolo then takes as client address the right-most
`X-Forwarded-For` entry that is not one of these proxies. Without it, Xolo
takes the left-most entry, which any client can forge to escape the per-IP
rate limit.

## Running several replicas

Some limits apply per replica and therefore grow with the number of
replicas: the per-IP rate limit, the rate limit of the provisionning API,
and the concurrency limits of subscription plans.

Each replica opens up to `database.pool.maxOpenConns` connections. Keep
`maxReplicas × maxOpenConns`, plus a margin for migrations and maintenance,
under the `max_connections` of PostgreSQL, or put PgBouncer in transaction
mode in front of it. Keep `database.pool.maxIdleConns` equal to
`maxOpenConns`, as by default. With fewer idle connections, the pool closes
and reopens connections on every burst, and a replica serves less.

## Sizing

The figures below come from the [bench](../../bench/README.md) of this
repository, on a kind cluster with a fake provider and short completions,
with Xolo 0.95.3. They give orders of magnitude. Measure your own traffic
before you size a production deployment.

Requests per second one replica serves:

| Replica | Without a plan | With a subscription plan |
|---|---|---|
| 0.5 vCPU | 140 | 60 |
| 1 vCPU | 300 | 140 |
| 2 vCPU | 500 | 200 |
| 4 vCPU | 600 | 240 |

Without a plan, a request costs Xolo 3.5 to 4 ms of CPU. A prompt guard
brings it to about 5.5 ms, and pseudonymization to about 8 ms. A replica
uses 120 to 340 MiB of memory, 470 MiB with the pseudonymizer loaded.
PostgreSQL uses 2 to 3 ms of CPU per request. Past 2 vCPU, add replicas
rather than CPU, and give the pool about 20 connections per vCPU.

Every request of an organization updates the same budget counters in the
database, so one organization has a ceiling whatever the number of replicas.
Four replicas of 1 vCPU served one organization 560 requests per second, the
highest rate measured, with a p95 time to first token of 110 ms. Traffic
spread over several organizations goes further.

With a subscription plan, every request also reads the plan's usage. The
figures above come from a plan with three windows and two API keys.
PostgreSQL then uses about 20 ms of CPU per request and becomes the limit, so
size it for that load.

Do not set a CPU limit. A throttled replica holds its database locks longer,
which lowers the ceiling of every organization it serves.
