# Enterprise MicroK8s on-prem platform - operator entry points.
# Usage: make <target> ENV=production

ENV            ?= staging
INVENTORY      ?= ansible/inventories/$(ENV)/hosts.yml
ANSIBLE_OPTS   ?=
KUBECONFIG     ?= $(HOME)/.kube/microk8s-$(ENV)
CHARTS         := microservice frontend tenant

export KUBECONFIG

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ---------- Cluster lifecycle (Ansible) ----------
.PHONY: deps preflight cluster addons gitops configmaps site upgrade backup
deps: ## Install Ansible collections (+ hvac for HashiCorp Vault lookups)
	ansible-galaxy collection install -r ansible/requirements.yml
	python3 -m pip install --user 'hvac>=2.1'

preflight: ## Validate hosts meet requirements
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/preflight.yml $(ANSIBLE_OPTS)

cluster: ## Prepare nodes and form the MicroK8s HA cluster
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/prepare-nodes.yml playbooks/cluster.yml $(ANSIBLE_OPTS)

addons: ## Enable MicroK8s base addons and fetch kubeconfig
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/addons.yml $(ANSIBLE_OPTS)

gitops: ## Install Argo CD and apply the root app-of-apps
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/bootstrap-gitops.yml $(ANSIBLE_OPTS)

configmaps: ## Render/apply tenant & service ConfigMaps (MODE=apply|gitops)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/configmaps.yml -e configmaps_mode=$(or $(MODE),gitops) $(ANSIBLE_OPTS)

site: ## Full install: nodes -> cluster -> addons -> GitOps
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/site.yml $(ANSIBLE_OPTS)

upgrade: ## Rolling MicroK8s upgrade, one node at a time
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/upgrade.yml $(ANSIBLE_OPTS)

backup: ## Back up the dqlite datastore
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/backup.yml $(ANSIBLE_OPTS)

## ---------- Edge load balancers, external Vault / MinIO, storage ----------
.PHONY: lb lb-certs lb-check vault-server vault-server-init vault-init-transit minio-server storage-prep
lb: ## Deploy HAProxy + keepalived edge load balancers (L7 default, lb_mode=l4 optional)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/loadbalancers.yml $(ANSIBLE_OPTS)

lb-certs: ## Sync TLS certificates to the load balancers (run daily)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/loadbalancers.yml --tags lb_certs $(ANSIBLE_OPTS)

lb-check: ## Dry-run the load balancer configuration (diff only)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/loadbalancers.yml --check --diff $(ANSIBLE_OPTS)

vault-server: ## Install/configure the external Vault HA cluster (vault_servers)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/vault-server.yml $(ANSIBLE_OPTS)

vault-server-init: ## First-time init of the external Vault (stores keys ansible-vault encrypted)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/vault-server.yml -e vault_server_init=true $(ANSIBLE_OPTS)

vault-init-transit: ## Init in-cluster Vault with transit auto-unseal from the external Vault
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/vault-init.yml -e vault_init_enabled=true -e vault_deployment_mode=external $(ANSIBLE_OPTS)

minio-server: ## Install the external MinIO backup cluster (minio_servers), buckets and consumer users
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/minio-server.yml $(ANSIBLE_OPTS)

storage-prep: ## Format/mount local NVMe and MinIO drives (never wipes used disks unless storage_prep_force=true)
	cd ansible && ansible-playbook -i ../$(INVENTORY) playbooks/storage-prep.yml $(if $(LIMIT),--limit $(LIMIT),) $(ANSIBLE_OPTS)

## ---------- Validation ----------
.PHONY: lint yamllint helm-lint helm-template ansible-lint validate
yamllint: ## Lint all YAML
	yamllint -c .yamllint.yaml .

helm-lint: ## Lint all local charts
	@for c in $(CHARTS); do helm lint charts/$$c || exit 1; done

helm-template: ## Render charts with CI values
	@for c in $(CHARTS); do \
	  for f in charts/$$c/ci/*.yaml; do [ -f "$$f" ] || continue; \
	    echo "== $$c $$f"; helm template t charts/$$c -f $$f > /dev/null || exit 1; done; \
	done

ansible-lint: ## Lint Ansible
	cd ansible && ansible-lint

validate: yamllint helm-lint helm-template ## Run all local validation

## ---------- Day-2 helpers ----------
.PHONY: argocd-password sync status rollouts
argocd-password: ## Print initial Argo CD admin password
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

status: ## Show Argo CD application health
	kubectl -n argocd get applications -o wide

rollouts: ## List Argo Rollouts across tenants
	kubectl get rollouts -A

## ---------- Local development ----------
.PHONY: dev-up dev-down
dev-up: ## Start local dependencies + services with docker compose
	docker compose -f services/docker-compose.yml up -d --build

dev-down: ## Stop local stack
	docker compose -f services/docker-compose.yml down -v
