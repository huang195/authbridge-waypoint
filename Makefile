REGISTRY ?= localhost:5000
TAG ?= latest
GOARCH ?= $(shell go env GOARCH)
CLUSTER_NAME ?= kagenti
SERVICES := demo-agent echo-tool time-tool token-exchange-service
REALM := waypoint-poc
KC_PORT := 18080

.PHONY: up test down

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
	@fuser -k $(KC_PORT)/tcp 2>/dev/null || true; \
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

down: ## Remove all PoC resources including Keycloak realm
	@echo "=== Removing Kubernetes resources ==="
	-kubectl delete -f deploy/08-workloads.yaml 2>/dev/null
	-kubectl delete -f deploy/07-istio-policies.yaml 2>/dev/null
	-kubectl delete -f deploy/06-waypoint.yaml 2>/dev/null
	-kubectl delete -f deploy/05-token-exchange-svc.yaml 2>/dev/null
	-kubectl delete ns agent-ns tool-ns 2>/dev/null
	@echo "=== Removing Keycloak realm ==="
	@fuser -k $(KC_PORT)/tcp 2>/dev/null || true; \
		kubectl port-forward -n keycloak svc/keycloak-service $(KC_PORT):8080 & PF_PID=$$!; \
		sleep 3; \
		ADMIN_TOKEN=$$(curl -sf -X POST "http://localhost:$(KC_PORT)/realms/master/protocol/openid-connect/token" \
			-d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token'); \
		if [ -n "$$ADMIN_TOKEN" ] && [ "$$ADMIN_TOKEN" != "null" ]; then \
			curl -sf -X DELETE "http://localhost:$(KC_PORT)/admin/realms/$(REALM)" \
				-H "Authorization: Bearer $$ADMIN_TOKEN" \
				&& echo "   Deleted realm '$(REALM)'" \
				|| echo "   Realm '$(REALM)' already gone"; \
		else \
			echo "   WARNING: Could not get admin token — realm not deleted"; \
		fi; \
		kill $$PF_PID 2>/dev/null || true
	-rm -rf bin/
