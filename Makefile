REGISTRY ?= localhost:5000
TAG ?= latest
# Detect host arch for Kind (macOS arm64 = Kind arm64 nodes)
GOARCH ?= $(shell go env GOARCH)
# Name of the local kagenti Kind cluster (must already be running)
CLUSTER_NAME ?= kagenti

SERVICES := echo-agent echo-tool token-exchange-service

.PHONY: build images deploy test clean setup teardown help

help: ## Show this help menu
	@echo "Usage: make [target]"
	@echo ""
	@echo "Prerequisites: a local kagenti cluster (Kind + Istio ambient + Keycloak)"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

build: ## Build all services (linux/$(GOARCH))
	@for svc in $(SERVICES); do \
		echo "Building $$svc (linux/$(GOARCH))..."; \
		CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o bin/$$svc ./cmd/$$svc/; \
	done

images: build ## Build Docker images for all services
	@for svc in $(SERVICES); do \
		echo "Building image for $$svc..."; \
		docker build -t $(REGISTRY)/$$svc:$(TAG) --build-arg SERVICE=$$svc -f Dockerfile .; \
	done

push: images ## Push images to registry
	@for svc in $(SERVICES); do \
		docker push $(REGISTRY)/$$svc:$(TAG); \
	done

setup: ## Configure Keycloak realm, deploy namespaces and waypoint
	@if ! kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_NAME)'; then \
		echo "ERROR: kagenti cluster '$(CLUSTER_NAME)' not found. Please deploy it first."; \
		exit 1; \
	fi
	@echo "=== Configuring Keycloak realm and clients ==="
	@echo "  (port-forward to kagenti Keycloak for setup)"
	kubectl port-forward -n keycloak svc/keycloak-service 18080:8080 & PF_PID=$$!; \
		sleep 5; \
		bash deploy/03-keycloak-setup.sh; \
		kill $$PF_PID 2>/dev/null || true
	@echo "=== Creating namespaces and waypoint ==="
	kubectl apply -f deploy/04-namespaces.yaml
	kubectl apply -f deploy/06-waypoint.yaml

deploy: images ## Build, load images into Kind, and deploy workloads
	@echo "=== Loading images into Kind ==="
	@for svc in $(SERVICES); do \
		kind load docker-image $(REGISTRY)/$$svc:$(TAG) --name $(CLUSTER_NAME); \
	done
	@echo "=== Deploying token-exchange-service ==="
	kubectl apply -f deploy/05-token-exchange-svc.yaml
	@echo "=== Applying Istio policies ==="
	kubectl apply -f deploy/07-istio-policies.yaml
	@echo "=== Deploying workloads ==="
	kubectl apply -f deploy/08-workloads.yaml

test: ## Run end-to-end tests
	bash deploy/09-test.sh

clean: ## Remove build artifacts
	rm -rf bin/

teardown: ## Remove deployed resources (keeps the kagenti cluster)
	-kubectl delete -f deploy/08-workloads.yaml 2>/dev/null
	-kubectl delete -f deploy/07-istio-policies.yaml 2>/dev/null
	-kubectl delete -f deploy/06-waypoint.yaml 2>/dev/null
	-kubectl delete -f deploy/05-token-exchange-svc.yaml 2>/dev/null
	-kubectl delete -f deploy/04-namespaces.yaml 2>/dev/null

all: setup deploy test ## Full setup, deploy, and test
