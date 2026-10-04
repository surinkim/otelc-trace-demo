#!/usr/bin/env bash
# 요청을 몇십 개 보내서 트레이스를 쌓는다. 사용법: ./load.sh [포트, 기본 8080]
port=${1:-8080}
base="http://localhost:${port}"
for i in $(seq 1 20); do
  id=$(( RANDOM % 120 + 1 ))         # 101~120은 없는 id → 404
  curl -s -o /dev/null -w "GET /users/${id} %{http_code}\n" "${base}/users/${id}"
done
for i in 1 2 3; do
  curl -s -o /dev/null -w "GET /report %{http_code} %{time_total}s\n" "${base}/report"
done
curl -s -o /dev/null -w "GET /users-noctx/5 %{http_code}\n" "${base}/users-noctx/5"
