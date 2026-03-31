REGISTRY ?= localhost:5000
TAG ?= latest
GOARCH ?= $(shell go env GOARCH)
CLUSTER_NAME ?= kagenti
SERVICES := demo-agent echo-tool time-tool token-exchange-service
REALM := kagenti
KC_PORT := 18080

.PHONY: help up test down

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

up: ## Build, configure Keycloak, deploy everything
	@if ! kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_NAME)'; then \
		echo "ERROR: Kind cluster '$(CLUSTER_NAME)' not found."; exit 1; \
	fi
	@if ! kubectl get cm istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep -q kagenti-token-exchange; then \
		echo "ERROR: Istio mesh config missing 'kagenti-token-exchange' ext_authz provider."; exit 1; \
	fi
	@echo "=== Building ==="
	@for svc in $(SERVICES); do \
		CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o bin/$$svc ./cmd/$$svc/; \
	done
	@for svc in $(SERVICES); do \
		docker build -q -t $(REGISTRY)/$$svc:$(TAG) --build-arg SERVICE=$$svc -f Dockerfile .; \
		kind load docker-image $(REGISTRY)/$$svc:$(TAG) --name $(CLUSTER_NAME) 2>&1 | grep -v "^enabling"; \
	done
	@echo "=== Configuring Keycloak ==="
	@lsof -ti tcp:$(KC_PORT) | xargs kill 2>/dev/null || true; \
		kubectl port-forward -n keycloak svc/keycloak-service $(KC_PORT):8080 & PF_PID=$$!; \
		sleep 5; \
		bash deploy/03-keycloak-setup.sh; \
		kill $$PF_PID 2>/dev/null || true
	@echo "=== Deploying ==="
	kubectl apply -f deploy/04-namespaces.yaml
	kubectl apply -f deploy/06-waypoint.yaml
	kubectl apply -f deploy/05-token-exchange-svc.yaml
	kubectl apply -f deploy/07-istio-policies.yaml
	kubectl apply -f deploy/08-workloads.yaml
	@echo "=== Ready ==="

test: ## Run end-to-end tests
	bash deploy/09-test.sh

WAYPOINT_CLIENTS := demo-agent echo-tool time-tool token-exchange-service

down: ## Remove all PoC resources and Keycloak clients (realm is shared, not deleted)
	@echo "=== Removing Kubernetes resources ==="
	-kubectl delete -f deploy/08-workloads.yaml 2>/dev/null
	-kubectl delete -f deploy/07-istio-policies.yaml 2>/dev/null
	-kubectl delete -f deploy/06-waypoint.yaml 2>/dev/null
	-kubectl delete -f deploy/05-token-exchange-svc.yaml 2>/dev/null
	-kubectl delete ns agent-ns tool-ns 2>/dev/null
	@echo "=== Removing Keycloak clients (realm '$(REALM)' is shared) ==="
	@lsof -ti tcp:$(KC_PORT) | xargs kill 2>/dev/null || true; \
		kubectl port-forward -n keycloak svc/keycloak-service $(KC_PORT):8080 & PF_PID=$$!; \
		sleep 3; \
		ADMIN_TOKEN=$$(curl -sf -X POST "http://localhost:$(KC_PORT)/realms/master/protocol/openid-connect/token" \
			-d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token'); \
		if [ -n "$$ADMIN_TOKEN" ] && [ "$$ADMIN_TOKEN" != "null" ]; then \
			for CLIENT in $(WAYPOINT_CLIENTS); do \
				UUID=$$(curl -sf "http://localhost:$(KC_PORT)/admin/realms/$(REALM)/clients?clientId=$$CLIENT" \
					-H "Authorization: Bearer $$ADMIN_TOKEN" | jq -r '.[0].id'); \
				if [ -n "$$UUID" ] && [ "$$UUID" != "null" ]; then \
					curl -sf -o /dev/null -X DELETE "http://localhost:$(KC_PORT)/admin/realms/$(REALM)/clients/$$UUID" \
						-H "Authorization: Bearer $$ADMIN_TOKEN" \
						&& echo "   Deleted client '$$CLIENT'" \
						|| echo "   Client '$$CLIENT' already gone"; \
				fi; \
			done; \
		else \
			echo "   WARNING: Could not get admin token — clients not deleted"; \
		fi; \
		kill $$PF_PID 2>/dev/null || true
	-rm -rf bin/
