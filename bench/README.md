# Kubernetes bench

Deploys the chart on a local kind cluster, checks that the release works, and
measures its capacity with load campaigns. The upstream LLM provider is the
fake one of [xolo-chaos](https://github.com/xolo-gateway/xolo-chaos), and the
load comes from its k6 scripts.

## Contents

| Path | Role |
|---|---|
| `kind/cluster.yaml` | kind cluster with one control plane and three workers |
| `manifests/` | PostgreSQL (disposable, `fsync` off), the chaos provider, metrics-server |
| `images/xolo.Dockerfile` | Xolo image built from a local checkout, to test unreleased changes |
| `seed.sh` | fills the database (see below) |
| `sql/globex.sql` | gives the second organization of the dataset its own chaos provider |
| `sql/plan.sql` | puts the chaos providers under a subscription plan |
| `tls.sh` | creates the certificates of the provisionning API |
| `values-bench.yaml` | chart values for the bench: dev image, bench database, 0.5 vCPU per replica |
| `values-release.yaml` | on top of `values-bench.yaml`: the published image and the provisionning API |
| `validate.sh` | functional checks of a deployed release |
| `k6.sh` | one k6 load step, with the CPU used by Xolo and PostgreSQL |
| `campaign.sh` | load campaigns made of `k6.sh` steps |
| `k6/multi.js` | k6 script that spreads the load over several organizations |

## Requirements

kind, kubectl, Helm 3, Docker, Go, and the
[Xolo](https://github.com/xolo-gateway/xolo) and xolo-chaos repositories
checked out next to this one. `XOLO_DIR` and `CHAOS_DIR` override their paths.

## Setup

```bash
kind create cluster --config kind/cluster.yaml
kubectl label node xolo-worker bench/role=infra
kubectl label node xolo-worker2 xolo-worker3 bench/role=app

docker build -f images/xolo.Dockerfile -t xolo-server:dev ../../xolo
(cd ../.. && docker build -f xolo-chaos/deploy/chaos-provider.Dockerfile -t xolo-chaos/provider:dev .)
kind load docker-image xolo-server:dev xolo-chaos/provider:dev --name xolo

kubectl apply -f manifests/metrics-server.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl create ns bench
kubectl apply -f manifests/postgres.yaml -f manifests/chaos-provider.yaml
./seed.sh
./tls.sh

helm install xolo ../charts/xolo -n bench -f values-bench.yaml --wait
helm test xolo -n bench
```

The node labelled `bench/role=infra` runs PostgreSQL, the chaos provider and
k6. The two `app` nodes run the Xolo replicas.

`seed.sh` generates Xolo's dataset with `cmd/seed`, adds the chaos provider,
its models and pipelines from xolo-chaos, then applies `sql/globex.sql` and
`sql/plan.sql`. `PLAN=0` leaves the chaos providers on pay-as-you-go.

`sql/plan.sql` gives the chaos providers a plan with three shared windows
(5 hours, a week, a month) and a second API key whose week and month windows
start at other times. It spreads the existing usage records over the last 30
days as plan history. The budgets are out of reach, so the plan counts usage
but never refuses a request. Run it again after a campaign to spread the
records the campaign added.

`values-bench.yaml` holds the fixed `XOLO_SECRET_KEY` that decrypts the
provider keys of Xolo's dataset. It is public: never use it outside the
bench.

## Validation

```bash
helm upgrade xolo ../charts/xolo -n bench -f values-bench.yaml -f values-release.yaml --wait
./validate.sh
```

`validate.sh` checks, on the deployed release:

- `/healthz` and `/readyz` on every replica;
- a streamed and a non-streamed completion, and the three pipeline models;
- that an unknown token gets a 401;
- the provisionning API, with the client certificate of `tls.sh`, and without
  one;
- that the replicas logged no error and did not restart.

## Load campaigns

`k6.sh` runs one load step from inside the cluster, at a fixed arrival rate:

```bash
./k6.sh <name> <model> <rate> <duration> [prompt_set] [stream]
```

It writes the k6 summary and the CPU used by every Xolo replica and by
PostgreSQL, read from their cgroups, to `results/<name>.json` and
`results/<name>.meta.json`, and prints one line per step. `SCRIPT=multi.js`
with `TARGETS="token@org,token@org"` spreads the load over several
organizations.

`campaign.sh` chains steps. Each configuration starts on freshly restarted
replicas, and a series of steps stops at the first one whose p95 time to
first token exceeds 500 ms (`SLO_TTFT_MS`) or whose failed checks exceed 1%.
`ONLY` selects a phase:

| Phase | What it runs |
|---|---|
| `capacity` | one replica, short completions, with a prompt guard and with pseudonymization |
| `scaling` | 2, 3 and 4 replicas |
| `streams` | long streamed completions on 2 replicas |
| `resilience` | a rolling restart, then a pod deleted, while streams are in flight |
| `hpa` | autoscaling from 1 to 4 replicas under a steady load |
| `ceiling` | one organization on 2 and 4 replicas (`CEILING_RATES`, `CEILING_REPLICAS`) |
| `vertical` | one replica from 0.5 to 4 vCPU, two organizations (`VERTICAL_SIZES`) |

Without `ONLY`, the first five phases run in turn. `EXTRA_VALUES` adds Helm
arguments to every deployment, for instance
`EXTRA_VALUES="-f values-release.yaml"` to measure the published image.

## Limits

- Every kind node shares the host's cores. The replicas are capped at
  0.5 vCPU each, so their figures stand on their own, but PostgreSQL and k6
  are not capped and compete for the same cores.
- Apart from the `vertical` phase, the load comes from one user of one
  organization. Every request of an organization updates the same budget
  counters, so this is the worst case for them.
- k6 reads a streamed response as a whole. The time to first token it
  reports is the time to the first byte.
