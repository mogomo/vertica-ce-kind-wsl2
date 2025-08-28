# Makefile — Install Vertica Community Edition with 1-3 EON nodes on WSL2 with Kubernetes and MinIO
#
# Disclaimer: This Makefile is provided “as is” without any warranty. Use at your own risk.
#
# Purpose
#   Provision a local Vertica cluster on Ubuntu/WSL2 using kind (Kubernetes-in-Docker)
#   and MinIO for communal storage. Installs kubectl/kind/helm if missing, creates
#   a kind cluster with WSL-mounted PVs, installs MinIO + Vertica Operator, deploys
#   VerticaDB, waits for initialization, prints node health, and creates readable
#   host-path symlinks. Teardown removes everything and can optionally wipe PV data.
#
# Targets
#   up      Create/upgrade kind, MinIO, Vertica Operator, and VerticaDB; wait for
#		DBInitialized=True; print Vertica node health and PV path hints.
#   down	  Remove Vertica/Operator/MinIO/kind. With CLEAN_WSL=1 also deletes PV data
#		under $(WSL_DIR)/pv and symlinks in $(WSL_DIR)/links.
#   check-docker  Validate Docker CLI/daemon and show WSL setup tips.
#   help | usage  Show usage and current defaults (default target).
#
# Usage
#   sudo make <target> [VAR=VALUE ...]
#
# Options (override on the command line; defaults shown)
#   CLUSTER="$(CLUSTER)"		 - kind cluster name (context: kind-$(CLUSTER))
#   NS="$(NS)"		     - Kubernetes namespace
#   BUCKET="$(BUCKET)"	     - MinIO bucket for communal storage
#   WSL_DIR="$(WSL_DIR)"		 - WSL-visible root for PV (communal storage) data + symlinks
#   CLEAN_WSL="$(CLEAN_WSL)"	 - With 'down', set to 1 to wipe PV data and links
#   MINIO_USER="$(MINIO_USER)"     - MinIO root user (seeded on first install)
#   MINIO_PASS="$(MINIO_PASS)"     - MinIO root password (seeded on first install)
#   KIND_URL="$(KIND_URL)"	     - kind binary download URL if missing
#   DBADMIN_PASS="$(DBADMIN_PASS)"       - Vertica dbadmin (superuser) password. If set, creates Secret 'su-passwd'
#					 (key: password) and enables password authentication (spec.passwordSecret).
#   LICENSE_FILE="$(LICENSE_FILE)"       - Path to Vertica license .dat file. If set, creates Secret 'vertica-license'
#					 and adds spec.licenseSecret. License mounts at /home/dbadmin/licensing/mnt.
#
# Examples
#   make						- Show help/usage and current defaults.
#   sudo make up					- Provision everything; wait for DB to start; print Vertica node health.
#   sudo make up CLUSTER=dev BUCKET=mybucket WSL_DIR=/opt/vertica-kind    - Use custom cluster name, bucket, and WSL host storage root.
#   sudo make up MINIO_USER=admin MINIO_PASS='s3cret' BUCKET=vertica-communal   - Seed MinIO with explicit credentials and bucket.
#   sudo make up KIND_URL=https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64  - Override the kind binary download URL.
#   sudo make up DBADMIN_PASS='dbadmin_passwd'    	- Enable dbadmin password auth by creating 'su-passwd' Secret and wiring spec.passwordSecret.
#   sudo make up LICENSE_FILE=/path/to/license-file.dat - Provide Vertica license (Secret 'vertica-license' + spec.licenseSecret).
#   sudo make up DBADMIN_PASS='dbadmin_passwd' LICENSE_FILE=/path/to/license-file.dat - Set both dbadmin password and license for larger clusters.
#   sudo make down				    	- Uninstall Vertica/Operator/MinIO and delete kind cluster.
#   sudo make down CLUSTER=otherdev		  	- Uninstall. Specify the cluster name if you changed the default cluster name
#   sudo make down CLEAN_WSL=1		    		- Uninstall Vertica/Operator/MinIO,delete cluster, depots and communal data on WSL host.
#   sudo make check-docker			    	- Check Docker CLI/daemon and show WSL setup paths if missing.
#
# Notes:
#   - Automatic sizing by available RAM:
#       ≥ 6144 MiB → 3-node Vertica;  > 2048 MiB → 1-node;  otherwise aborts.
#   - PVCs + MinIO data live under $(WSL_DIR)/pv; symlinks appear in $(WSL_DIR)/links.
#   - Run inside Ubuntu/WSL2 with sudo (root) and a running Docker daemon.
#   - After the Vertica cluster is created, to run SQL statements, use -w "YOUR_DBADMIN_PASSWORD" if a dbadmin password was set:
#     vsql -h localhost -p 5433 -U dbadmin -w "YOUR_DBADMIN_PASSWORD" -c "YOUR SQL STATEMENT;"
##############################################################################################
.ONESHELL:
SHELL := /bin/bash
# Show help when no target is provided
.DEFAULT_GOAL := help

# ---- Config ----
CLUSTER   := vertica-local
NS	     := default
DB_NAME   := vdb
VERTICA_IMAGE    := opentext/vertica-k8s:25.3.0-0
BUCKET     := vertica-communal
MINIO_USER       := minio
MINIO_PASS       := minio123
K8S_DEB_CHANNEL  := v1.30
KIND_URL	 := https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
DBADMIN_PASS     :=
LICENSE_FILE     :=

# WSL-visible storage root for all PV data (override at runtime if you like)
WSL_DIR   := /opt/vertica-kind
CLEAN_WSL       := 0
KIND_CFG	 := kind-wsl.yaml

# --- background port-forward config ---
PF_DIR    := /tmp
PF_VERTICA_PORT := 5433
PF_MINIO_PORT   := 9001
PF_VERTICA_PID  := $(PF_DIR)/pf-vertica.$(CLUSTER).pid
PF_MINIO_PID    := $(PF_DIR)/pf-minio.$(CLUSTER).pid

# --- YOW = Yellow font On White
# --- WOB = White font On Black
YOB	  := \E[1;33;40m
WOB	  := \E[00m

# ---- Kind cluster config (written without heredocs) ----
define KIND_CFG_YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: __WSL_DIR__/pv
    containerPath: /var/local-path-provisioner
  - hostPath: __WSL_DIR__/pv
    containerPath: /opt/local-path-provisioner
endef
export KIND_CFG_YAML

# ---- VerticaDB Manifest ----
# NOTE: The 'size' field will be dynamically replaced based on available RAM.
define VERTICA_YAML
apiVersion: vertica.com/v1
kind: VerticaDB
metadata:
  name: $(DB_NAME)
  annotations:
    vertica.com/include-uid-in-path: "true"
    vertica.com/vcluster-ops: "true"
    vertica.com/k-safety: "0"
spec:
  image: $(VERTICA_IMAGE)
  dbName: $(DB_NAME)
  __LICENSE_SECRET_LINE__
  __PASSWORD_SECRET_LINE__
  communal:
    endpoint: http://minio:9000
    path: s3://$(BUCKET)/$(DB_NAME)
    credentialSecret: s3-creds
    region: us-east-1
  subclusters:
    - name: sc
      size: __VERTICA_SIZE__
  local:
    dataPath: /data

endef
export VERTICA_YAML # This makes the variable available to the shell

# ---- Usage text (printed by `make`, `make help`, or `make usage`) ----
define USAGE_TXT
Makefile — Install Vertica Community Edition with 1-3 EON nodes on WSL2 with Kubernetes and MinIO

USAGE
  sudo make <target> [VAR=VALUE ...]

TARGETS
  up	 Create/upgrade kind, MinIO, Vertica Operator, and VerticaDB;
		 wait for DBInitialized=True; print Vertica node health.
  down     Remove Vertica/Operator/MinIO/kind. With CLEAN_WSL=1 also deletes
		 host PV data under $(WSL_DIR)/pv and symlinks under $(WSL_DIR)/links.
  check-docker   Validate Docker CLI/daemon and show WSL setup tips.
  help | usage   Show this help (default target).
  pf-vertica     Start background port-forward to Vertica SQL (localhost:$(PF_VERTICA_PORT)).
  minio-console  Start background port-forward to MinIO Console (http://localhost:$(PF_MINIO_PORT)).

OPTIONS (current defaults)
  # kind cluster name		   CLUSTER="$(CLUSTER)"
  # Kubernetes namespace		NS="$(NS)"
  # MinIO bucket (communal storage)     BUCKET="$(BUCKET)"
  # WSL root dir for data + symlinks    WSL_DIR="$(WSL_DIR)"
  # With 'down', 1 = wipe PV data       CLEAN_WSL="$(CLEAN_WSL)"
  # MinIO root user (seeded once)       MINIO_USER="$(MINIO_USER)"
  # MinIO root password (seeded once)   MINIO_PASS="$(MINIO_PASS)"
  # kind binary download URL	    KIND_URL="$(KIND_URL)"
  # Vertica DB name		     DB_NAME="$(DB_NAME)"
  # Vertica dbadmin password	    DBADMIN_PASS="$(DBADMIN_PASS)"
  # Vertica license file (.dat)	 LICENSE_FILE="$(LICENSE_FILE)"

EXAMPLES
  $(YOB)make$(WOB)						- Show help/usage and current defaults (default goal).
  $(YOB)sudo make up$(WOB)					- Provision a Vertica EON cluster and start background port-forwards
  $(YOB)sudo make up CLUSTER=dev BUCKET=mybucket WSL_DIR=/opt/vertica-kind$(WOB)
						- Use custom cluster name, bucket, and WSL storage path
  $(YOB)sudo make up MINIO_USER=admin MINIO_PASS='s3cret' BUCKET=vertica-communal$(WOB)
						- Seed MinIO with explicit credentials and bucket
  $(YOB)sudo make up KIND_URL=https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64$(WOB)
						- Override the kind binary download URL
  $(YOB)sudo make up DBADMIN_PASS='dbadmin_passwd'$(WOB)	- Change dbadmin password
  $(YOB)sudo make up LICENSE_FILE=/path/to/license-file.dat$(WOB)
						- Upgrade the Vertica Community Edition to a licensed EON cluster
  $(YOB)sudo make up DBADMIN_PASS='dbadmin_passwd' LICENSE_FILE=/path/to/license-file.dat$(WOB)
						- Set both dbadmin password and license
  $(YOB)sudo make down$(WOB)				- Uninstall Vertica,Operator,MinIO and delete kind cluster; stop background port-forwards
  $(YOB)sudo make down CLEAN_WSL=1$(WOB)			- Uninstall all and delete EON communal data on the WSL host
  $(YOB)sudo make down CLUSTER=dev$(WOB)			- Use if you changed the default (vdb) cluster name
  $(YOB)sudo make check-docker$(WOB)			- Check Docker CLI/daemon and show WSL setup guidance if missing
  $(YOB)sudo make pf-vertica$(WOB)				- Start (or confirm) background port-forward to Vertica SQL
  $(YOB)sudo make minio-console$(WOB)			- Start (or confirm) background port-forward to MinIO Console.

NOTES
  - Vertica EON Node count chosen automatically by free RAM:
      >= 6144 MiB → 3 nodes;
      > 2048 MiB → 1 node;
      Otherwise aborts.
  - Data paths:
      PVCs + MinIO: $(WSL_DIR)/pv
      Symlinks:     $(WSL_DIR)/links

  - After the Vertica cluster is created, to run SQL statements, use -w "YOUR_DBADMIN_PASSWORD" if a dbadmin password was set:
    ${YOB}vsql -h localhost -p 5433 -U dbadmin -w "YOUR_DBADMIN_PASSWORD" -c "YOUR SQL STATEMENT;"${WOB}

endef
export USAGE_TXT

.PHONY: help usage
help usage:
	@echo -e "$$USAGE_TXT"

.PHONY: up down check-docker pf-vertica minio-console
up:     check-docker
	@set -euo pipefail

	# Surface optional inputs to the shell (may be empty)
	LICENSE_FILE="$(LICENSE_FILE)"; DBADMIN_PASS="$(DBADMIN_PASS)"

	# --- Check available RAM and set node count ---
	AVAILABLE_MEM_MB=$$(( $$(grep '^MemAvailable:' /proc/meminfo | sed -E 's/^MemAvailable:[[:space:]]*([0-9]+).*/\1/') / 1024 ))
	VERTICA_NODE_COUNT=0
	if (( $$AVAILABLE_MEM_MB >= 6144 )); then # 6 GiB = 6144 MiB
		VERTICA_NODE_COUNT=3
		echo ">>>> Good, sufficient RAM available ($$AVAILABLE_MEM_MB MiB). Deploying 3-node Vertica cluster."
	elif (( $$AVAILABLE_MEM_MB > 2048 )); then # 2 GiB = 2048 MiB
		VERTICA_NODE_COUNT=1
		echo ">>>> Sorry, limited RAM available ($$AVAILABLE_MEM_MB MiB). Deploying 1-node Vertica cluster."
	else
		echo ">>>> Error, insufficient RAM available ($$AVAILABLE_MEM_MB MiB). At least 2GiB is required to create the cluster. Aborting."
		exit 1
	fi

	# --- Install kubectl (apt), kind, helm (idempotent) ---
	apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg >/dev/null
	if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then \
	  curl -fsSL https://pkgs.k8s.io/core:/stable:/$(K8S_DEB_CHANNEL)/deb/Release.key \
		| gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; \
	fi
	echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$(K8S_DEB_CHANNEL)/deb/ /' \
	  > /etc/apt/sources.list.d/kubernetes.list
	apt-get update >/dev/null
	apt-get install -y kubectl >/dev/null

	if ! command -v kind >/dev/null; then \
	  curl -Lo /usr/local/bin/kind $(KIND_URL) && chmod +x /usr/local/bin/kind; \
	fi
	if ! command -v helm >/dev/null; then \
	  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; \
	fi

	# --- Create kind cluster (if missing), with WSL mount for PVs ---
	mkdir -p "$(WSL_DIR)/pv"
	MODIFIED_KIND_CFG=$$(printf '%s\n' "$$KIND_CFG_YAML" | sed "s|__WSL_DIR__|$(WSL_DIR)|g")
	printf '%s' "$$MODIFIED_KIND_CFG" > $(KIND_CFG)

	if ! kind get clusters | grep -qx '$(CLUSTER)'; then \
	  kind create cluster --name $(CLUSTER) --config $(KIND_CFG); \
	else \
	  # Non-breaking: warn if an existing cluster wasn't created with the mount
	  if ! docker inspect $(CLUSTER)-control-plane 2>/dev/null | grep -Eq '/(var|opt)/local-path-provisioner'; then \
		echo ">>>> WARNING: Existing kind cluster '$(CLUSTER)' may lack the WSL PV mount."; \
		echo ">>>> To ensure PVC data lands in $(WSL_DIR)/pv, run: make down && make up"; \
	  fi; \
	fi
	kubectl config use-context kind-$(CLUSTER) >/dev/null

	# --- Ensure a StorageClass exists (kind usually sets one) ---
	kubectl get storageclass >/dev/null 2>&1 || true

	# --- Helm repos + MinIO install ---
	helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
	helm repo add vertica https://vertica.github.io/charts >/dev/null 2>&1 || true
	helm repo update >/dev/null

	helm upgrade --install minio bitnami/minio \
	  --set auth.rootUser=$(MINIO_USER),auth.rootPassword=$(MINIO_PASS) \
	  --set defaultBuckets=$(BUCKET) \
	  --set resources.requests.memory=512Mi

	# Wait for MinIO deployments ready
	kubectl -n $(NS) rollout status deployment/minio --timeout=300s
	kubectl -n $(NS) rollout status deployment/minio-console --timeout=300s

	# --- Prove MinIO is actually ready (in-cluster) ---
	kubectl -n $(NS) delete pod minio-ready >/dev/null 2>&1 || true
	kubectl -n $(NS) run minio-ready --restart=Never --image=curlimages/curl -- \
	  -sSf http://minio:9000/minio/health/ready
	for i in {1..30}; do \
	  phase="$$(kubectl -n $(NS) get pod minio-ready -o jsonpath='{.status.phase}' 2>/dev/null || echo Pending)"; \
	  if [ "$$phase" = "Succeeded" ]; then break; fi; \
	  if [ "$$phase" = "Failed" ]; then echo "MinIO not ready"; kubectl -n $(NS) logs minio-ready || true; exit 1; fi; \
	  sleep 2; \
	done
	kubectl -n $(NS) delete pod minio-ready >/dev/null 2>&1 || true

	# --- Create/verify S3 bucket via mc (MUST succeed) ---
	ROOT_USER="$$(kubectl -n $(NS) get secret minio -o jsonpath='{.data.root-user}' | base64 -d)"
	ROOT_PASS="$$(kubectl -n $(NS) get secret minio -o jsonpath='{.data.root-password}' | base64 -d)"

	kubectl -n $(NS) delete pod mc-create-bucket >/dev/null 2>&1 || true
	kubectl -n $(NS) run mc-create-bucket \
	--restart=Never \
	--image=docker.io/bitnami/minio-client:2025.7.21-debian-12-r2 \
	--env MINIO_URL="http://minio:9000" \
	--env MINIO_USER="$$ROOT_USER" \
	--env MINIO_PASS="$$ROOT_PASS" \
	--command -- /bin/bash -lc 'set -eo pipefail; \
	export PATH=/opt/bitnami/minio-client/bin:"$$PATH"; \
	mc alias set local "$$MINIO_URL" "$$MINIO_USER" "$$MINIO_PASS"; \
	mc ls local/$(BUCKET) >/dev/null 2>&1 || mc mb -p local/$(BUCKET); \
	mc ls local/$(BUCKET) >/dev/null'

	for i in {1..60}; do \
	phase="$$(kubectl -n $(NS) get pod mc-create-bucket -o jsonpath='{.status.phase}' 2>/dev/null || echo Pending)"; \
	if [ "$$phase" = "Succeeded" ]; then break; fi; \
	if [ "$$phase" = "Failed" ]; then echo "Bucket create/verify failed:"; kubectl -n $(NS) logs mc-create-bucket || true; exit 1; fi; \
	sleep 2; \
	done
	kubectl -n $(NS) delete pod mc-create-bucket >/dev/null 2>&1 || true

	# --- Install Vertica Operator + wait ---
	helm upgrade --install vertica-operator vertica/verticadb-operator
	kubectl -n $(NS) rollout status deployment/verticadb-operator-manager --timeout=300s

	# --- Create Vertica S3 creds Secret (idempotent) ---
	kubectl -n $(NS) get secret s3-creds >/dev/null 2>&1 || \
	  kubectl -n $(NS) create secret generic s3-creds \
			--from-literal=accesskey="$$ROOT_USER" \
			--from-literal=secretkey="$$ROOT_PASS"

	# --- Optional: create Vertica license/password secrets if provided (idempotent) ---
	if [ -n "$$LICENSE_FILE" ]; then \
	  kubectl -n $(NS) get secret vertica-license >/dev/null 2>&1 || \
	  kubectl -n $(NS) create secret generic vertica-license --from-file=license.dat="$$LICENSE_FILE"; \
	fi
	if [ -n "$$DBADMIN_PASS" ]; then \
	  kubectl -n $(NS) get secret su-passwd >/dev/null 2>&1 || \
	  kubectl -n $(NS) create secret generic su-passwd --from-literal=password="$$DBADMIN_PASS"; \
	fi

	# --- Write VerticaDB manifest (with dynamic node count + optional secrets) ---
	MODIFIED_VERTICA_YAML=$$(printf '%s\n' "$$VERTICA_YAML" | sed \
	  -e "s/__VERTICA_SIZE__/$$VERTICA_NODE_COUNT/" \
	  -e "s|__LICENSE_SECRET_LINE__|$${LICENSE_FILE:+licenseSecret: vertica-license}|" \
	  -e "s|__PASSWORD_SECRET_LINE__|$${DBADMIN_PASS:+passwordSecret: su-passwd}|")
	printf '%s' "$$MODIFIED_VERTICA_YAML" > vertica3.yaml

	# --- Ensure admission webhook Service has endpoints ---
	for i in {1..60}; do \
	  EP="$$(kubectl -n $(NS) get endpoints verticadb-operator-webhook-service \
		-o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"; \
	  [ -n "$$EP" ] && break; \
	  sleep 2; \
	done
	[ -n "$$EP" ] || { echo "Webhook service has no endpoints"; \
				kubectl -n $(NS) get svc,endpoints verticadb-operator-webhook-service; exit 1; }


	# --- Apply VerticaDB + wait until DBInitialized (with diagnostics) ---
	echo "Applying VerticaDB manifest..."
	kubectl apply -f vertica3.yaml

	echo "Waiting up to 10m for $(DB_NAME) to reach DBInitialized=True..."
	if ! kubectl wait --for=condition=DBInitialized=True vdb/$(DB_NAME) --timeout=10m; then \
	  echo "==== VerticaDB describe ===="; \
	  kubectl describe vdb $(DB_NAME) || true; \
	  echo "==== Operator logs (last 1000 lines) ===="; \
	  kubectl logs deploy/verticadb-operator-manager --tail=1000 || true; \
	  echo "==== Vertica pods ===="; \
	  kubectl get pods -l app.kubernetes.io/name=vertica -o wide || true; \
	  echo "==== Describe Vertica pod(s) ===="; \
	  kubectl describe pod -l app.kubernetes.io/name=vertica || true; \
	  echo "==== PVC/PV ===="; \
	  kubectl get pvc,pv || true; \
	  echo "==== Recent cluster events ===="; \
	  kubectl get events --sort-by=.lastTimestamp | tail -n 200 || true; \
	  echo "DB initialization did not complete. See diagnostics above."; \
	  exit 1; \
	fi

	# Print timing note only for a 3-node cluster
	if (( $$VERTICA_NODE_COUNT == 3 )); then
	echo ""
	echo "For a 3-node cluster, if you see details below for only one node, it's just a matter of timing."
	echo "To reliably view all nodes, wait a bit and query the nodes table again later."
	echo ""
	fi
	# --- Show node health ---
	POD="$$(kubectl get pod -l app.kubernetes.io/name=vertica -o jsonpath='{.items[0].metadata.name}')"
	echo "Vertica nodes:"
	if [ -n "$$DBADMIN_PASS" ]; then PASS_OPT="-w $$DBADMIN_PASS"; else PASS_OPT="-w ''"; fi
	kubectl exec -i "$$POD" -c server -- /opt/vertica/bin/vsql -U dbadmin $$PASS_OPT \
	  -c "select node_name,node_state,is_primary,node_address,catalog_path,node_type,is_ephemeral,subcluster_name,build_info from nodes;"
	echo ""
	echo "After the Vertica cluster is created, run SQL statements. Use -w "Your dbadmin passwd" if dbadmin passwd was set:"
	echo -e '$(YOB)vsql -h localhost -p 5433 -U dbadmin -w "" -c "YOUR SQL STATEMENT;"$(WOB)'

	# --- Minimal additions: start background port-forwards (idempotent-ish) ---
	# Vertica SQL → localhost:$(PF_VERTICA_PORT)
	if [ ! -s "$(PF_VERTICA_PID)" ] || ! ps -p "$$(cat $(PF_VERTICA_PID))" >/dev/null 2>&1; then \
	  kubectl -n $(NS) wait --for=condition=Ready pod -l app.kubernetes.io/name=vertica --timeout=5m; \
	  VPOD="$$(kubectl -n $(NS) get pod -l app.kubernetes.io/name=vertica -o jsonpath='{.items[0].metadata.name}')"; \
	  nohup kubectl -n $(NS) port-forward "$$VPOD" $(PF_VERTICA_PORT):5433 >/dev/null 2>&1 & echo $$! > $(PF_VERTICA_PID); \
	  echo "pf-vertica: localhost:$(PF_VERTICA_PORT) (PID $$(cat $(PF_VERTICA_PID)))"; \
	else \
	  echo "pf-vertica already running (PID $$(cat $(PF_VERTICA_PID)))"; \
	fi
	# MinIO Console → http://localhost:$(PF_MINIO_PORT)
	if [ ! -s "$(PF_MINIO_PID)" ] || ! ps -p "$$(cat $(PF_MINIO_PID))" >/dev/null 2>&1; then \
	  nohup kubectl -n $(NS) port-forward svc/minio-console $(PF_MINIO_PORT):9001 >/dev/null 2>&1 & echo $$! > $(PF_MINIO_PID); \
	  echo "pf-minio-console: http://localhost:$(PF_MINIO_PORT) (PID $$(cat $(PF_MINIO_PID)))"; \
	else \
	  echo "pf-minio-console already running (PID $$(cat $(PF_MINIO_PID)))"; \
	fi

	# --- Surface WSL paths for all PVCs (non-intrusive helpers) ---
	echo ""
	echo "---- WSL storage root ----"
	echo "All MinIO + Vertica PVC data lives under: $(WSL_DIR)/pv"
	echo "Creating readable symlinks under: $(WSL_DIR)/links"
	mkdir -p "$(WSL_DIR)/links"

	# Map PVCs to host paths and create helpful symlinks
	kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.volumeName}{"\n"}{end}' \
	| while IFS=$$'\t' read -r NSPVC PV; do \
		[ -n "$$PV" ] && [ -e "$(WSL_DIR)/pv/$$PV" ] || continue; \
		LINK="$(WSL_DIR)/links/$$(echo $$NSPVC | tr '/' '_')"; \
		ln -sfn "$(WSL_DIR)/pv/$$PV" "$$LINK"; \
	  done

	echo ""
	echo "PVC → host path mapping:"
	if [ -d "$(WSL_DIR)/links" ]; then \
	  ls -1 "$(WSL_DIR)/links" | while read L; do \
		echo "$$L -> $(WSL_DIR)/links/$$L"; \
	  done; \
	fi
	echo "Tip: ls -lah $(WSL_DIR)/pv"

# --- Helpers (one-liners) ---
pf-vertica:
	@set -e
	kubectl -n $(NS) wait --for=condition=Ready pod -l app.kubernetes.io/name=vertica --timeout=5m
	POD="$$(kubectl -n $(NS) get pod -l app.kubernetes.io/name=vertica -o jsonpath='{.items[0].metadata.name}')"
	if [ ! -s "$(PF_VERTICA_PID)" ] || ! ps -p "$$(cat $(PF_VERTICA_PID))" >/dev/null 2>&1; then \
	  nohup kubectl -n $(NS) port-forward "$$POD" $(PF_VERTICA_PORT):5433 >/dev/null 2>&1 & echo $$! > $(PF_VERTICA_PID); \
	fi
	@echo "Vertica SQL → localhost:$(PF_VERTICA_PORT)  (PID $$(cat $(PF_VERTICA_PID)))"

minio-console:
	@set -e
	if [ ! -s "$(PF_MINIO_PID)" ] || ! ps -p "$$(cat $(PF_MINIO_PID))" >/dev/null 2>&1; then \
	  nohup kubectl -n $(NS) port-forward svc/minio-console $(PF_MINIO_PORT):9001 >/dev/null 2>&1 & echo $$! > $(PF_MINIO_PID); \
	fi
	@echo "MinIO Console → http://localhost:$(PF_MINIO_PORT)  (PID $$(cat $(PF_MINIO_PID)))"

down:
	@set -euo pipefail
	# Minimal additions: stop background port-forwards (ignore errors)
	if [ -f "$(PF_VERTICA_PID)" ]; then kill "$$(cat $(PF_VERTICA_PID))" >/dev/null 2>&1 || true; rm -f "$(PF_VERTICA_PID)"; fi
	if [ -f "$(PF_MINIO_PID)" ]; then kill "$$(cat $(PF_MINIO_PID))" >/dev/null 2>&1 || true; rm -f "$(PF_MINIO_PID)"; fi
	# Check if kind cluster exists
	if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER)'; then \
		# Use context only if it exists
		kubectl config get-contexts -o name | grep -qx 'kind-$(CLUSTER)' && \
		  kubectl config use-context kind-$(CLUSTER) >/dev/null || true; \
		# If Vertica CRD exists, delete CRs quickly (no waits)
		if kubectl get crd verticadbs.vertica.com --request-timeout=5s >/dev/null 2>&1; then \
			kubectl -n $(NS) delete vdb $(DB_NAME) --ignore-not-found --wait=false --request-timeout=10s || true; \
			[ -f vertica3.yaml ] && kubectl delete -f vertica3.yaml --ignore-not-found --wait=false --request-timeout=10s || true; \
		fi; \
		# Nuke possible leftovers (best-effort, fast timeouts)
		kubectl -n $(NS) delete statefulset $(DB_NAME)-sc --ignore-not-found --wait=false --request-timeout=10s || true; \
		kubectl -n $(NS) delete pvc -l app.kubernetes.io/instance=minio --ignore-not-found --wait=false --request-timeout=10s || true; \
		kubectl -n $(NS) delete pvc -l app.kubernetes.io/name=vertica --ignore-not-found --wait=false --request-timeout=10s || true; \
		# Helm uninstalls without waiting (don’t block on a dead API)
		helm --kube-context kind-$(CLUSTER) uninstall vertica-operator --wait=false >/dev/null 2>&1 || true; \
		helm --kube-context kind-$(CLUSTER) uninstall minio --wait=false >/dev/null 2>&1 || true; \
	fi; \
	# Always remove the kind cluster (fast if already gone)
	kind delete cluster --name $(CLUSTER) >/dev/null 2>&1 || true
	# Clean kubeconfig noise
	kubectl config delete-context kind-$(CLUSTER) >/dev/null 2>&1 || true
	kubectl config delete-cluster kind-$(CLUSTER) >/dev/null 2>&1 || true
	kubectl config delete-user kind-$(CLUSTER) >/dev/null 2>&1 || true
	@if [ "$(CLEAN_WSL)" = "1" ]; then \
		echo "CLEAN_WSL=1 → removing PV data under $(WSL_DIR)   pv dir and links dir"; \
		rm -rf "$(WSL_DIR)/pv" "$(WSL_DIR)/links" 2>/dev/null || true; \
	fi
	echo "Cleaned up: cluster $(CLUSTER) removed."

check-docker:
	@set -e
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "ERROR: Docker CLI not found."; \
		if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then \
			echo ""; \
			echo "WSL install options:"; \
			echo "  A) Docker Desktop (recommended)"; \
			echo "     - Install Docker Desktop on Windows"; \
			echo "     - Open Docker Desktop → Settings → Resources → WSL integration → enable for your Ubuntu distro"; \
			echo ""; \
			echo "  B) Docker Engine inside WSL (requires systemd)"; \
			echo "     sudo tee /etc/wsl.conf >/dev/null <<'EOF'"; \
			echo "     [boot]"; \
			echo "     systemd=true"; \
			echo "     EOF"; \
			echo "     In Windows PowerShell:  wsl --shutdown"; \
			echo "     Back in WSL:     sudo apt-get update && sudo apt-get install -y docker.io"; \
			echo "	 sudo systemctl enable --now docker"; \
		else \
			echo "Please install Docker Engine: https://docs.docker.com/engine/install/"; \
		fi; \
		exit 1; \
	fi
	@if ! docker info >/dev/null 2>&1; then \
		echo "ERROR: Docker daemon is not running."; \
		if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then \
			echo "Start Docker Desktop on Windows, or run: sudo systemctl start docker (if you installed Engine in WSL)"; \
		else \
			echo "Start the Docker service: sudo systemctl start docker"; \
		fi; \
		exit 1; \
	fi

