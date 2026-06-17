# CrossLink Signal Server
FROM golang:1.24-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY signal/ ./signal/
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /crosslink-signal ./signal/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /crosslink-signal /usr/local/bin/crosslink-signal
EXPOSE 18080
USER nobody
ENTRYPOINT ["crosslink-signal"]
