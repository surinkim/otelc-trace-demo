# 같은 main.go를 두 가지 방법으로 빌드한다.
#   make plain   → go build        → bin/plain (트레이스 X)
#   make otel    → otelc go build  → bin/otel  (트레이스 O)
OTELC ?= otelc

.PHONY: plain otel up down load console clean

plain:
	go build -o bin/plain .

otel:
	$(OTELC) go build -o bin/otel .

# Grafana까지 포함한 전체 데모 (Docker만 있으면 됨)
up:
	docker compose up -d --build
	@echo "Grafana: http://localhost:3000  (Explore → Tempo)"

down:
	docker compose down

load:
	./load.sh 8080

# 서버 없이 트레이스를 파일로만 남기기 (Go 1.26+, otelc, Redis 필요)
#   docker compose up -d redis 로 Redis만 띄운 뒤 실행한다.
console: otel
	GIN_MODE=release OTEL_SERVICE_NAME=otelc-demo OTEL_TRACES_EXPORTER=console \
	OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
	./bin/otel > traces.jsonl

clean:
	rm -rf bin .otelc-build traces.jsonl
