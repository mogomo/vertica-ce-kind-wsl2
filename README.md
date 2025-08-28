# vertica-ce-kind-wsl2
Makefile to spin up a local Vertica EON cluster on Windows WSL2 using Kubernetes and MinIO

Provision a **local Vertica Community Edition (EON)** cluster (1–3 nodes, auto-sized by available RAM) on **Ubuntu under WSL2** using **kind (Kubernetes-in-Docker)**, **MinIO** for communal S3, and the **VerticaDB Operator**. The included **Makefile** installs any missing tools, creates the kind cluster, installs MinIO + the operator, deploys a `VerticaDB`, waits for initialization, and starts helpful port-forwards.

> **Intended for local test and demos, not for production.** Provided “as is” with no warranties.

---

## Requirements
- **Windows 10/11** with **WSL2** and an **Ubuntu** distro (sudo access)
- **Docker** available inside WSL (Docker Desktop with WSL integration, or Docker Engine on WSL with systemd)
- **Network access** to fetch binaries/charts
- **Memory gates**: ≥ **6144 MiB** free → **3 nodes**; > **2048 MiB** free → **1 node**; otherwise aborts

---

## Quick Start
```bash
# Run inside Ubuntu/WSL (sudo needed because tools/packages may be installed)
sudo make up
# Optional: set dbadmin password and a Vertica license
sudo make up DBADMIN_PASS='StrongPassword' LICENSE_FILE=/path/to/license.dat
```
On success, the script prints Vertica node health and starts local port-forwards.

---

## Make Targets
- `make up` — Provision/upgrade everything (kind, MinIO, operator, VerticaDB), wait for `DBInitialized=True`, print health, start forwards.
- `make down` — Remove Vertica/Operator/MinIO/kind and stop forwards. Add `CLEAN_WSL=1` to also wipe local PV data & symlinks.
- `make pf-vertica` — Ensure a background port-forward to Vertica SQL on `localhost:5433`.
- `make minio-console` — Ensure a background port-forward to MinIO Console on `http://localhost:9001`.
- `make check-docker` — Diagnose Docker CLI/daemon in WSL.
- `make help` — Show usage with current defaults.

---

## Configuration (override on the make command line)
| Variable | Default | Description |
|---|---:|---|
| `CLUSTER` | `vertica-local` | kind cluster name (`kind-<CLUSTER>`) |
| `NS` | `default` | Kubernetes namespace |
| `DB_NAME` | `vdb` | Vertica database/CR name |
| `VERTICA_IMAGE` | `opentext/vertica-k8s:25.3.0-0` | Vertica image tag |
| `BUCKET` | `vertica-communal` | MinIO bucket for communal storage |
| `MINIO_USER` | `minio` | MinIO root user |
| `MINIO_PASS` | `minio123` | MinIO root password |
| `WSL_DIR` | `/opt/vertica-kind` | WSL root for PV data & readable symlinks |
| `PF_VERTICA_PORT` | `5433` | Local Vertica SQL port-forward |
| `PF_MINIO_PORT` | `9001` | Local MinIO Console port-forward |

Examples:
```bash
  make                                          - Show help/usage and current defaults (default goal).
  sudo make up                                  - Provision a Vertica EON cluster and start background port-forwards
  sudo make up MINIO_USER=admin MINIO_PASS='s3cret' BUCKET=vertica-communal
                                                - Seed MinIO with explicit credentials and bucket
  sudo make up DBADMIN_PASS='dbadmin_passwd'    - Change dbadmin password
  sudo make up LICENSE_FILE=/path/to/license-file.dat
                                                - Upgrade the Vertica Community Edition to a licensed EON cluster
  sudo make up DBADMIN_PASS='dbadmin_passwd' LICENSE_FILE=/path/to/license-file.dat
                                                - Set both dbadmin password and license
  sudo make down                                - Uninstall Vertica,Operator,MinIO and delete kind cluster; stop background port-forwards
  sudo make down CLEAN_WSL=1                    - Uninstall all and delete EON communal data on the WSL host

```

---

## Connect
**Vertica (vsql):**
```bash
# Use -w only if you set DBADMIN_PASS
vsql -h 127.0.0.1 -p 5433 -U dbadmin -w "<YOUR_DBADMIN_PASSWORD>" -c "select version();"
```

**MinIO Console:** open **http://localhost:9001** and log in with `MINIO_USER` / `MINIO_PASS` (defaults: `minio` / `minio123`). The communal bucket is `BUCKET` (default `vertica-communal`).

---

## Data & Paths (WSL)
- PVC data root: `$(WSL_DIR)/pv`
- Readable PVC symlinks: `$(WSL_DIR)/links` (e.g., `default/minio`, `default/vdb-*`)

---

## Cleanup
```bash
sudo make down                # remove cluster + apps
sudo make down CLEAN_WSL=1    # same + wipe local PV data & symlinks
```

---

## Notes
- Optimized for **Ubuntu on WSL2**. It can work on native Linux, but WSL storage paths/notes are WSL-centric.
- Defaults are for local, non-production use. Override credentials & versions as needed.
