#!/usr/bin/env bash
# otelc로 빌드한 서버(8080)와 go build로 빌드한 서버(8081)에 같은 부하를 주고 비교한다.
# 사용법: docker compose up -d --build 후 ./bench.sh [요청 수] [동시 접속] [반복 횟수] [경로]
set -euo pipefail
N=${1:-20000}
C=${2:-10}
ROUNDS=${3:-3}
URL_PATH=${4:-/users/1}
SOCK=${DOCKER_SOCK:-/var/run/docker.sock}

# 컨테이너가 지금까지 쓴 CPU 시간(ns)과 메모리(anon, bytes)
stats() {
  curl -s --unix-socket "$SOCK" "http://localhost/containers/$1/stats?stream=false" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["cpu_stats"]["cpu_usage"]["total_usage"], d["memory_stats"]["stats"]["anon"])'
}

run() { # name port container_id
  ab -q -k -n "$N" -c "$C" "http://127.0.0.1:$2$URL_PATH" >/dev/null 2>&1   # 워밍업
  read -r cpu0 _ < <(stats "$3")
  out=$(ab -q -k -n "$N" -c "$C" "http://127.0.0.1:$2$URL_PATH" 2>&1)
  read -r cpu1 mem < <(stats "$3")
  rps=$(awk '/^Requests per second/ {print $4}' <<<"$out")
  mean=$(awk '/^Time per request/ && /\(mean\)/ {print $4; exit}' <<<"$out")
  p50=$(awk '$1=="50%" {print $2}' <<<"$out")
  p99=$(awk '$1=="99%" {print $2}' <<<"$out")
  # ab의 Failed requests는 응답 길이만 달라도 센다(캐시 hit/miss). 실패는 non-2xx로 본다.
  non2xx=$(awk '/^Non-2xx responses/ {print $3}' <<<"$out"); non2xx=${non2xx:-0}
  cpu_us=$(( (cpu1 - cpu0) / N / 1000 ))
  printf "%-6s %9s %8s %7s %7s %10s %8s %7s\n" "$1" "$rps" "$mean" "$p50" "$p99" "$cpu_us" "$((mem / 1024 / 1024))" "$non2xx" | tee -a "$ROWS"
}

ROWS=$(mktemp)
OTEL=$(docker compose ps -q app-otel)
PLAIN=$(docker compose ps -q app-plain)

echo "GET $URL_PATH  n=$N c=$C rounds=$ROUNDS"
printf "%-6s %9s %8s %7s %7s %10s %8s %7s\n" build "req/s" "mean ms" "p50ms" "p99ms" "CPU us/req" "mem MB" non2xx
for r in $(seq 1 "$ROUNDS"); do
  run otel 8080 "$OTEL"
  run plain 8081 "$PLAIN"
done

echo "--- 중앙값"
python3 - "$ROWS" <<'PY'
import statistics, sys
rows = [l.split() for l in open(sys.argv[1])]
for name in ("otel", "plain"):
    cols = list(zip(*[r[1:7] for r in rows if r[0] == name]))
    med = [statistics.median(map(float, c)) for c in cols]
    print(f"{name:<6} {med[0]:9.0f} {med[1]:8.3f} {med[2]:7.0f} {med[3]:7.0f} {med[4]:10.0f} {med[5]:8.0f}")
PY
rm -f "$ROWS"
