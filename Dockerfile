# BUILD=otel  → otelc go build (트레이스 O)
# BUILD=plain → go build       (트레이스 X)
FROM golang:1.26 AS build
ARG BUILD=otel
WORKDIR /src
RUN go install go.opentelemetry.io/otelc/tool/cmd/otelc@v1.1.0
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN if [ "$BUILD" = "otel" ]; then \
      CGO_ENABLED=0 otelc go build -o /out/app . ; \
    else \
      CGO_ENABLED=0 go build -o /out/app . ; \
    fi

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
