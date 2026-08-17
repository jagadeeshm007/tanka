# ClickHouse on Kubernetes — Makefile
#
# Environment path structure: environments/{cloud}/{tier}/{component}
#
# Usage:
#   make <target>                          # uses defaults below
#   make <target> CLOUD=local TIER=development
#   make apply-all                         # apply all components in order

CLOUD ?= local
TIER  ?= development
BASE  := environments/$(CLOUD)/$(TIER)

NAMESPACE := clickhouse
CH_POD    := $(shell kubectl get pod -n $(NAMESPACE) -l clickhouse.altinity.com/chi=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
KEEPER_POD := $(shell kubectl get pod -n $(NAMESPACE) -l clickhouse-keeper.altinity.com/chk=clickhouse-keeper -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
# Default-user password is read straight from the Secret — never hardcoded here.
CH_PASS   := $(shell kubectl get secret clickhouse-credentials -n $(NAMESPACE) -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

# ─── Per-component Tanka targets ──────────────────────────────────────────────

.PHONY: show-core show-operator show-keeper show-clickhouse
show-core:        ## Preview core (namespace + priority class)
	tk show $(BASE)/core --dangerous-allow-redirect
show-operator:    ## Preview clickhouse-operator Helm chart rendering
	tk show $(BASE)/clickhouse-operator --dangerous-allow-redirect
show-keeper:      ## Preview ClickHouseKeeperInstallation
	tk show $(BASE)/clickhouse-keeper --dangerous-allow-redirect
show-clickhouse:  ## Preview ClickHouseInstallation + PVC
	tk show $(BASE)/clickhouse --dangerous-allow-redirect

.PHONY: diff-core diff-operator diff-keeper diff-clickhouse
diff-core:        ## Diff core against cluster
	tk diff $(BASE)/core
diff-operator:    ## Diff operator against cluster
	tk diff $(BASE)/clickhouse-operator
diff-keeper:      ## Diff keeper against cluster
	tk diff $(BASE)/clickhouse-keeper
diff-clickhouse:  ## Diff clickhouse against cluster
	tk diff $(BASE)/clickhouse

.PHONY: apply-core apply-operator apply-keeper apply-clickhouse
apply-core:       ## Apply core (namespace + priority class + network policies)
	tk apply $(BASE)/core --auto-approve=always
apply-operator:   ## Apply clickhouse-operator
	tk apply $(BASE)/clickhouse-operator --auto-approve=always
apply-keeper:     ## Apply ClickHouseKeeperInstallation
	tk apply $(BASE)/clickhouse-keeper --auto-approve=always
apply-clickhouse: ## Apply ClickHouseInstallation
	tk apply $(BASE)/clickhouse --auto-approve=always

.PHONY: create-secret
create-secret: ## Create the default-user password Secret (generates one if unset)
	./scripts/create-secret.sh $(NAMESPACE) $$(kubectl config current-context)

.PHONY: vendor-and-apply-all
vendor-and-apply-all: vendor-charts create-secret apply-core apply-operator apply-keeper apply-clickhouse ## Full bootstrap in dependency order

.PHONY: apply-all
apply-all: apply-core apply-operator apply-keeper apply-clickhouse ## Apply all components in dependency order

# ─── Status ───────────────────────────────────────────────────────────────────

.PHONY: status
status: ## Show CHI, CHK, pods, PVCs, services at a glance
	@echo "\n=== ClickHouseInstallation (CHI) ==="
	kubectl get chi -n $(NAMESPACE)
	@echo "\n=== ClickHouseKeeperInstallation (CHK) ==="
	kubectl get chk -n $(NAMESPACE)
	@echo "\n=== Pods ==="
	kubectl get pods -n $(NAMESPACE)
	@echo "\n=== PersistentVolumeClaims ==="
	kubectl get pvc -n $(NAMESPACE)
	@echo "\n=== Services ==="
	kubectl get svc -n $(NAMESPACE)

.PHONY: operator-status
operator-status: ## Show operator pod and Helm release
	@echo "\n=== Helm Release ==="
	helm list -n clickhouse-operator
	@echo "\n=== Operator Pod ==="
	kubectl get pods -n clickhouse-operator

.PHONY: keeper-status
keeper-status: ## Show Keeper connection from inside ClickHouse
	kubectl exec -n $(NAMESPACE) $(CH_POD) -- \
		clickhouse-client --password "$(CH_PASS)" --query \
		"SELECT name, host, port, session_uptime_elapsed_seconds FROM system.zookeeper_connection FORMAT Pretty"

# ─── Connect ──────────────────────────────────────────────────────────────────

.PHONY: connect
connect: ## Open interactive clickhouse-client shell (auth from Secret)
	kubectl exec -it -n $(NAMESPACE) $(CH_POD) -- clickhouse-client --password "$(CH_PASS)"

.PHONY: query
query: ## Run a query: make query Q="SELECT version()"
	@test -n "$(Q)" || (echo "Usage: make query Q=\"SELECT version()\"" && exit 1)
	kubectl exec -n $(NAMESPACE) $(CH_POD) -- clickhouse-client --password "$(CH_PASS)" --query "$(Q)"

# ─── Logs ─────────────────────────────────────────────────────────────────────

.PHONY: logs-ch logs-keeper logs-operator
logs-ch:          ## Tail ClickHouse server logs
	kubectl logs -n $(NAMESPACE) $(CH_POD) -f
logs-keeper:      ## Tail Keeper logs
	kubectl logs -n $(NAMESPACE) $(KEEPER_POD) -f
logs-operator:    ## Tail Altinity operator logs
	kubectl logs -n clickhouse-operator \
		-l app.kubernetes.io/name=altinity-clickhouse-operator \
		-c altinity-clickhouse-operator -f

# ─── Validate ─────────────────────────────────────────────────────────────────

.PHONY: validate
validate: ## End-to-end validation: auth + version + Keeper + create/insert/select
	@echo "==> Auth check (passwordless must be REJECTED)..."
	@if kubectl exec -n $(NAMESPACE) $(CH_POD) -- clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then \
		echo "  FAIL: passwordless access succeeded — auth is not enforced!"; exit 1; \
	else echo "  OK: passwordless access rejected."; fi
	@echo "==> ClickHouse version..."
	kubectl exec -n $(NAMESPACE) $(CH_POD) -- clickhouse-client --password "$(CH_PASS)" --query "SELECT version()"
	@echo "==> Runtime user (must be non-root uid 101)..."
	kubectl exec -n $(NAMESPACE) $(CH_POD) -- id
	@echo "==> Keeper connection..."
	kubectl exec -n $(NAMESPACE) $(CH_POD) -- clickhouse-client --password "$(CH_PASS)" --query \
		"SELECT host, port, session_uptime_elapsed_seconds FROM system.zookeeper_connection FORMAT Pretty"
	@echo "==> Smoke test (create, insert, select)..."
	kubectl exec -n $(NAMESPACE) $(CH_POD) -- clickhouse-client --password "$(CH_PASS)" --multiquery --query \
		"CREATE DATABASE IF NOT EXISTS test; \
		 CREATE TABLE IF NOT EXISTS test.smoke_test \
		   (id UInt64, val String, ts DateTime) \
		   ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/smoke_test', '{replica}') \
		   ORDER BY (ts, id); \
		 INSERT INTO test.smoke_test VALUES (1, 'ok', now()); \
		 SELECT * FROM test.smoke_test;"
	@echo "==> Validation passed."

# ─── Helm chart vendoring ──────────────────────────────────────────────────────

.PHONY: vendor-charts
vendor-charts: ## Re-vendor Helm charts (run after changing chartfile.yaml)
	cd $(BASE)/clickhouse-operator && tk tool charts vendor

# ─── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo "Usage: make <target> [CLOUD=local] [TIER=development]\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-22s %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
