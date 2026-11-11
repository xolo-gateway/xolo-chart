#!/bin/bash
# Capacity and scaling campaign on the kind cluster. Each configuration starts
# from freshly created, warmed-up replicas: chained steps on long-lived
# replicas underestimate the high steps.
set -uo pipefail
cd "$(dirname "$0")"
NS=bench
SLO_TTFT_MS=${SLO_TTFT_MS:-500}
exec > >(tee -a results/campaign.log) 2>&1

replicas() {
  helm upgrade xolo ../charts/xolo -n $NS -f values-bench.yaml ${EXTRA_VALUES:-} --set autoscaling.enabled=false --set replicaCount=$1 --wait --timeout 5m >/dev/null
  kubectl -n $NS rollout restart deploy/xolo >/dev/null
  kubectl -n $NS rollout status deploy/xolo --timeout=5m >/dev/null
  # Wait for the old pods to be gone so cpu.stat is read on the new set only.
  while [ "$(kubectl -n $NS get pods -l app.kubernetes.io/name=xolo -o name | wc -l)" -ne "$1" ]; do sleep 2; done
}

# step <name> <model> <set> <rate...>: stops at the first rate over the SLO.
step() {
  local name=$1 model=$2 set=$3; shift 3
  ./k6.sh "$name-warmup" "$model" 5 15s "$set" >/dev/null
  for rate in "$@"; do
    out=$(./k6.sh "$name-r$rate" "$model" "$rate" "${DURATION:-45s}" "$set")
    echo "$out"
    p95=$(sed -n 's/.*ttft_p95_ms=\([0-9.]*\).*/\1/p' <<<"$out")
    err=$(sed -n 's/.* errors=\([0-9.]*\).*/\1/p' <<<"$out")
    if python3 -c "import sys; sys.exit(0 if $p95 > $SLO_TTFT_MS or $err > 0.01 else 1)"; then
      echo "  -> $name: SLO broken at $rate req/s"
      break
    fi
  done
}

echo "=== campaign $(date -Is) image $(kubectl -n $NS get deploy xolo -o jsonpath="{.spec.template.spec.containers[0].image}" 2>/dev/null) ==="

if [ -z "${ONLY:-}" ] || [ "$ONLY" = capacity ]; then
echo "##### 1. One replica, 0.5 vCPU #####"
replicas 1
step cap1-fast chaos-fast plain 40 60 80 100 120 140
step cap1-guard chaos-guard plain 20 40 60 80
step cap1-pseudo chaos-pseudo pii 10 20 30 40
fi

if [ -z "${ONLY:-}" ] || [ "$ONLY" = scaling ]; then
echo "##### 2. Horizontal scaling #####"
replicas 2; step cap2-fast chaos-fast plain 120 160 200 240 280
replicas 3; step cap3-fast chaos-fast plain 200 250 300 350 400
replicas 4; step cap4-fast chaos-fast plain 280 340 400 460 520
fi

if [ -z "${ONLY:-}" ] || [ "$ONLY" = streams ]; then
echo "##### 3. Long streams (chaos-slow: TTFT ~800 ms, 30 tok/s) #####"
replicas 2
for rate in 20 50 100; do ./k6.sh "slow2-r$rate" chaos-slow "$rate" 60s plain; done
fi
if [ -z "${ONLY:-}" ] || [ "$ONLY" = resilience ]; then
echo "##### 4. Rollout and pod loss under load (chaos-slow streams, ~5 s each) #####"
replicas 3
./k6.sh warm-res chaos-fast 5 10s >/dev/null
# A rolling restart while streams are in flight: with the pre-stop pause and
# the shutdown timeout, no stream should be cut.
( sleep 25; echo "  rollout restart at $(date +%T)"; kubectl -n $NS rollout restart deploy/xolo >/dev/null ) &
./k6.sh res-rollout chaos-slow 30 90s plain
wait
kubectl -n $NS rollout status deploy/xolo --timeout=5m >/dev/null
# A replica killed without warning: its in-flight streams are lost, the
# others must keep serving.
( sleep 25; p=$(kubectl -n $NS get pods -l app.kubernetes.io/name=xolo -o name | head -1); echo "  force-deleting $p at $(date +%T)"; kubectl -n $NS delete "$p" --grace-period=0 --force >/dev/null 2>&1 ) &
./k6.sh res-kill chaos-slow 30 90s plain
wait
fi

if [ -z "${ONLY:-}" ] || [ "$ONLY" = hpa ]; then
echo "##### 5. Autoscaling 1 -> 4 replicas, target 70 % CPU of the 500m request #####"
helm upgrade xolo ../charts/xolo -n $NS -f values-bench.yaml ${EXTRA_VALUES:-} --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=1 --set autoscaling.maxReplicas=4 \
  --set autoscaling.behavior.scaleUp.stabilizationWindowSeconds=0 --wait --timeout 5m >/dev/null
sleep 60
( for i in $(seq 1 40); do echo "  t+$((i*10))s replicas=$(kubectl -n $NS get deploy xolo -o jsonpath='{.status.readyReplicas}') cpu=$(kubectl -n $NS get hpa xolo -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')%"; sleep 10; done ) &
WATCH=$!
./k6.sh hpa-ramp chaos-fast 150 240s plain
kill $WATCH 2>/dev/null
helm upgrade xolo ../charts/xolo -n $NS -f values-bench.yaml ${EXTRA_VALUES:-} --set autoscaling.enabled=false --set replicaCount=2 --wait >/dev/null
fi
if [ "${ONLY:-}" = ceiling ]; then
echo "##### 6. Ceiling of one organization (${LABEL:-}) #####"
if [ -n "${CEILING_RATES:-}" ]; then
  replicas ${CEILING_REPLICAS:-4}; step ${LABEL:-x}-c${CEILING_REPLICAS:-4} chaos-fast plain $CEILING_RATES
else
  replicas 2; step ${LABEL:-x}-c2 chaos-fast plain 160 200 260 320
  replicas 4; step ${LABEL:-x}-c4 chaos-fast plain 200 260 320 400 480
fi
fi
if [ "${ONLY:-}" = vertical ]; then
echo "##### 7. Vertical scaling: one replica, 0.5 to 4 vCPU, two organizations #####"
export SCRIPT=multi.js TARGETS="xolo-e2e-alice-acme@acme,xolo-e2e-erin-globex@globex"
size() {
  helm upgrade xolo ../charts/xolo -n $NS -f values-bench.yaml ${EXTRA_VALUES:-} --set autoscaling.enabled=false --set replicaCount=1 \
    --set resources.requests.cpu=$1 --set resources.limits.cpu=$1 \
    --set resources.requests.memory=512Mi --set resources.limits.memory=2Gi --wait --timeout 5m >/dev/null
  kubectl -n $NS rollout restart deploy/xolo >/dev/null
  kubectl -n $NS rollout status deploy/xolo --timeout=5m >/dev/null
  while [ "$(kubectl -n $NS get pods -l app.kubernetes.io/name=xolo -o name | wc -l)" -ne 1 ]; do sleep 2; done
}
# VERTICAL_SIZES="cpu:rate rate…;cpu:rate…" overrides the default ladder.
IFS=';' read -ra sizes <<<"${VERTICAL_SIZES:-0.5:60 80 100 120 140;1:140 180 220 260 300;2:300 360 420 500 600;4:500 600 700 800 900 1000}"
for entry in "${sizes[@]}"; do
  cpu=${entry%%:*}
  size "$cpu"; step ${LABEL:-v}-v${cpu/./} chaos-fast plain ${entry#*:}
done
unset SCRIPT TARGETS
if [ -z "${SKIP_STREAMS:-}" ]; then
  # chaos-slow only exists in acme: one organization, it holds no hot row.
  echo "  long streams on one 4 vCPU replica (chaos-slow, ~10 s each)"
  size 4
  for rate in 100 200 300 400; do ./k6.sh ${LABEL:-v}-v4-slow-r$rate chaos-slow $rate 60s plain; done
fi
fi
echo "=== done $(date -Is) ==="
