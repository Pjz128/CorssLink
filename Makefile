.PHONY: all build test clean run-signal run-agent run-client poc

GO := go
GOPATH_CACHE := $(HOME)/go-cache
GOPROXY ?= https://goproxy.cn,direct
GOENV := GOPATH=$(GOPATH_CACHE) GOPROXY=$(GOPROXY)

# ---- POC ----
poc-signal:
	$(GOENV) $(GO) run ./poc/signal/

poc-agent:
	$(GOENV) $(GO) run ./poc/agent/

poc-client:
	$(GOENV) $(GO) run ./poc/client/

poc-test:
	@echo "=== Running POC end-to-end ==="
	$(GOENV) $(GO) build -o /tmp/poc-signal ./poc/signal/ && \
	$(GOENV) $(GO) build -o /tmp/poc-agent ./poc/agent/ && \
	$(GOENV) $(GO) build -o /tmp/poc-client ./poc/client/
	/tmp/poc-signal &
	sleep 1
	/tmp/poc-agent &
	sleep 2
	/tmp/poc-client

# ---- POC Direct (no signaling) ----
poc-direct:
	$(GOENV) $(GO) run ./poc/direct/

# ---- Signal Server ----
signal-build:
	$(GOENV) $(GO) build -o bin/crosslink-signal ./signal/

signal-run:
	$(GOENV) $(GO) run ./signal/

# ---- Agent ----
agent-build:
	$(GOENV) $(GO) build -o bin/crosslink-agent ./agent/

agent-run:
	$(GOENV) $(GO) run ./agent/

# ---- Licenser ----
licenser-build:
	$(GOENV) $(GO) build -o bin/licenser ./licenser/

# ---- QA ----
unit:
	$(GOENV) $(GO) test ./...

vet:
	$(GOENV) $(GO) vet ./...

lint:
	$(GOENV) $(GO) vet ./... && test -z "$$(gofmt -l . 2>/dev/null)"

# ---- App ----
app-analyze:
	cd app && flutter analyze

app-build-android:
	cd app && flutter build apk --release

app-build-ios:
	cd app && flutter build ios --release --no-codesign

# ---- Docker ----
docker-signal:
	docker build -t crosslink-signal -f signal/Dockerfile .

# ---- Clean ----
clean:
	rm -rf bin/ /tmp/poc-*.exe
