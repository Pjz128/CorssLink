# CrossLink Cloud Relay Server
FROM golang:1.24-alpine AS builder

WORKDIR /app
COPY poc/go.mod poc/go.sum ./
RUN go mod download
COPY poc/relay/ ./relay/
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /crosslink-relay ./relay/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /crosslink-relay /usr/local/bin/crosslink-relay
EXPOSE 18080
USER nobody
ENTRYPOINT ["crosslink-relay"]
