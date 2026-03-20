REGISTRY ?= localhost:5000
TAG ?= latest
# Detect host arch for Kind (macOS arm64 = Kind arm64 nodes)
GOARCH ?= $(shell go env GOARCH)

SERVICES := echo-agent echo-tool token-exchange-service

.PHONY: build images deploy test clean setup teardown

build:
	@for svc in $(SERVICES); do \
		echo "Building $$svc (linux/$(GOARCH))..."; \
		CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o bin/$$svc ./cmd/$$svc/; \
	done

images: build
	@for svc in $(SERVICES); do \
		echo "Building image for $$svc..."; \
		docker build -t $(REGISTRY)/$$svc:$(TAG) --build-arg SERVICE=$$svc -f Dockerfile .; \
	done

push: images
	@for svc in $(SERVICES); do \
		docker push $(REGISTRY)/$$svc:$(TAG); \
	done

setup:
	@echo "=== Creating Kind cluster ==="
	kind create cluster --config deploy/00-kind-cluster.yaml --name waypoint-poc
	@echo "=== Installing Istio ambient ==="
	bash deploy/01-istio-ambient.sh
	@echo "=== Deploying Keycloak ==="
	kubectl apply -f deploy/02-keycloak.yaml
	kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=180s
	@echo "=== Configuring Keycloak token exchange permissions ==="
	@echo "  (port-forward to Keycloak for setup)"
	kubectl port-forward -n keycloak svc/keycloak 18080:8080 & PF_PID=$$!; \
		sleep 5; \
		bash deploy/03-keycloak-setup.sh; \
		kill $$PF_PID 2>/dev/null || true
	@echo "=== Creating namespaces and waypoint ==="
	kubectl apply -f deploy/04-namespaces.yaml
	kubectl apply -f deploy/06-waypoint.yaml

deploy: images
	@echo "=== Loading images into Kind ==="
	@for svc in $(SERVICES); do \
		kind load docker-image $(REGISTRY)/$$svc:$(TAG) --name waypoint-poc; \
	done
	@echo "=== Deploying token-exchange-service ==="
	kubectl apply -f deploy/05-token-exchange-svc.yaml
	@echo "=== Applying Istio policies ==="
	kubectl apply -f deploy/07-istio-policies.yaml
	@echo "=== Deploying workloads ==="
	kubectl apply -f deploy/08-workloads.yaml

test:
	bash deploy/09-test.sh

clean:
	rm -rf bin/

teardown:
	kind delete cluster --name waypoint-poc

all: setup deploy test
