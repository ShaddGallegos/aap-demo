# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

## Choose your platform

| Host | Installation, configuration, and daily use |
|------|--------------------------------------------|
| RHEL / Fedora | [Linux quickstart](Linux_Quickstart.md) |
| macOS (Intel / Apple Silicon) | [macOS quickstart](MAC_Quickstart.md) |
| Windows / Hyper-V | [Windows quickstart](Windows_Quickstart.md) |
| WSL terminal, Windows-hosted CRC | [WSL quickstart](WSL_Quickstart.md) |

Linux/macOS use the Bash CLI; Windows uses the native PowerShell CLI. WSL
should invoke that Windows CLI instead of creating a second CRC installation.
CLI portability does not make every addon image available for every architecture.

| Capability | Native Linux | macOS | Native Windows / WSL wrapper |
|------------|--------------|-------|-------------------------------|
| CRC + AAP core lifecycle | Bash | Bash | PowerShell |
| Fleet | QEMU/KVM | QEMU/HVF, matching guest architecture | Not native PowerShell |
| Separate persistent image disk | libvirt | Use OCI cache instead | Not supported |
| Shutdown backup + pre-login boot recovery | systemd/libvirt | No | No |
| Explicit checkpoint + login recovery | systemd boot workflow | LaunchAgent, vfkit/raw | Native scheduled task, supported Hyper-V layout |
| Addon integrations | Bash, subject to images/tools | Bash, subject to images/tools | Native subset; other addons require Git Bash/tools |

Native macOS/Windows recovery is a **checkpoint-before-reboot** workflow, not
a guaranteed shutdown backup. It must still be validated with real CRC VMs on
those hosts; hermetic tests and CI checks are not equivalent to live recovery.
See [state recovery](docs/state-service.md) for retention, credentials and rollback
semantics. The Linux bootstrap below is **not** a macOS/Windows/WSL installer.

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **16 GB RAM minimum** — default VM allocation is 16 GB (override with
  `CRC_MEMORY=24576 aap-demo create` for 24 GB). On Linux, `aap-demo create`
  prompts for optional temp swap on memory-constrained hosts (see
  [scripts/README.md](scripts/README.md))
- **Pull secret** — download from the
  [Red Hat console](https://console.redhat.com/openshift/install/pull-secret) to
  `~/Downloads/pull-secret.txt` (or pass its location with `--pull-secret`).

## Install

Download your pull secret to `~/Downloads/pull-secret.txt`, then run:

```bash
git clone https://github.com/ShaddGallegos/aap-demo.git
cd aap-demo
./scripts/local-prereq.sh --full
```

On Linux x86_64, `--full` installs CRC when needed, installs `aap-demo`, creates and
deploys the local AAP environment, then enables MCP Server, APME, Product Demos, and
Automation Orchestrator. It automatically imports `~/Downloads/pull-secret.txt`; use
`--pull-secret /path/to/pull-secret.txt` when the download is elsewhere. Optional APME
GitHub integration can be configured later.

For AAP without the addon suite, use `./install.sh && aap-demo deploy`.

`aap-demo create` provisions the MicroShift VM only. `aap-demo deploy` installs OLM and AAP
(use `deploy` for the typical path; `create` alone is for cluster-only setup).

Cluster credentials live at `~/.aap-demo/kubeconfig.microshift` and are **not** merged into
`~/.kube/config`. If you relied on the old default kubeconfig behavior, run:

```bash
export KUBECONFIG=~/.aap-demo/kubeconfig.microshift
# or: aap-demo kubeconfig   # refresh file and print export command
```

## Status

```bash
aap-demo version       # Tool version, commit, and build timestamp
aap-demo status        # Show routes and health without secret values
aap-demo status --show-secrets  # Reveal credentials in an interactive terminal
```

```text
AAP Demo Status
===============

Infra:       OpenShift Local (CRC)
Cluster:     running (crc-microshift)

Namespaces:
-----------
  aap-operator         27/29 pods   aap

AAP Deployments:
----------------
  https://aap-aap-operator.apps.127.0.0.1.nip.io

Credentials: hidden (run 'aap-demo status --show-secrets' in a terminal to reveal)

Addons:
-------
  mcp-server      disabled
  portal          disabled
  portal-operator disabled (AMD64 only)
  setup-pah       disabled
  ao            disabled
  apme-eap        disabled
  local-cache     disabled
  product-demos       disabled
  product-demo-satellite  disabled
```

## Addons to add additional functionality

```bash
aap-demo enable              # List all addons
aap-demo enable portal       # Installs Automation Portal
aap-demo enable portal-operator # Installs Operator-based Portal (Technology Preview; AMD64 only)
aap-demo enable setup-pah     # Configures Private Automation Hub Credentials
aap-demo enable mcp-server   # MCP server for AI assistants
aap-demo enable ao           # Automation Orchestrator (GA; no aapctl required — see addons/ao/README.md)
aap-demo enable apme-eap     # Early Access Program only for APME
aap-demo enable local-cache  # Caches AAP containers locally so you don't re-download after destroy/create

# Ansible Product Demos - Official demo content from ansible/product-demos
aap-demo enable product-demos        # Five domains at once (includes base; Satellite opt-in)
aap-demo enable product-demo-satellite  # Satellite demos (requires a Satellite server)
aap-demo disable addon_name  # Disables addon
```

When destroying a running cluster, `aap-demo destroy` asks whether to save the
container images locally. Confirming lets the next `aap-demo deploy` reuse the
cached containers instead of downloading them again. Existing cached images are
loaded automatically at the start of the next deploy.

Normal destroy/recreate flow:

```bash
aap-demo destroy   # answer y at the cache prompt
aap-demo create
aap-demo deploy     # automatically loads the saved cache
```

You do not need to run `aap-demo enable local-cache load` for this normal flow.

To manage the cache manually:

```bash
aap-demo enable local-cache load   # one-shot reload into fresh VM
aap-demo enable local-cache        # restore auto-load on future deploys
```

### Common Commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7
aap-demo create --full-demo  # Create AAP + Ollama/AO + three RHEL 9 Fleet nodes + dashboard

# Cluster management
aap-demo status              # Show cluster status and routes; secrets stay hidden
aap-demo status --show-secrets # Reveal credentials interactively
aap-demo stop                # Stop the cluster
aap-demo start               # Resume the configured demo and wait for readiness
aap-demo ssh                 # SSH into the cluster node
aap-demo watch               # Monitor deployment progress
aap-demo destroy             # Delete entire cluster

# AAP Operator Idle
aap-demo idle true           # Scale down AAP to save resources
aap-demo idle false          # Scale back up
aap-demo idle                # Check current idle state

# Troubleshooting
aap-demo diagnose            # Quick health check (cluster, storage, SCCs, pods)
aap-demo must-gather         # Collect full diagnostics (AAP + cluster)
aap-demo must-gather /tmp/d  # Collect to specific directory
aap-demo repair              # Fix after sleep/wake issues

# Maintenance
aap-demo maintenance         # Preview reclaimable VM runtime data
aap-demo maintenance --apply # Remove exited containers, unused images, and old caches/logs
aap-demo maintenance uninstall         # Preview complete environment removal
aap-demo maintenance uninstall --apply # Remove VMs, caches, trust, CLI, and residual state
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Pull latest code and reinstall
aap-demo help                # Full command reference
```

`aap-demo create --full-demo` is a noninteractive, fail-fast demo bootstrap.
It creates a cluster sized for the included addons, deploys AAP 2.7, enables
Ollama and Automation Orchestrator, enables Fleet, creates and registers three
RHEL 9 nodes, reapplies integration wiring, and launches the dashboard. Fleet
image download and AAP subscription attachment require configured Red Hat
credentials. Run `aap-demo fleet auth` once before the full demo. Reruns reuse
existing Fleet nodes instead of creating duplicates. Use `--no-open` to run
the dashboard without opening a browser.

### Dashboard

`aap-demo dashboard` starts the localhost dashboard **in the background** and
returns to your terminal after its HTTP listener is ready. It opens your browser
unless you pass `--no-open`. Running the command again reuses the dashboard for
this checkout rather than starting a duplicate.

The Environment Overview shows the host OS and, when available, the CRC guest OS.
The small **Restart dashboard** button reloads the dashboard server and reconnects
the page without restarting CRC, AAP or Fleet. Restart is blocked during an active
dashboard add-on operation.

The default address is `http://127.0.0.1:8765`; set `AAP_DEMO_DASHBOARD_PORT`
to choose another port. Logs go to `~/.aap-demo/dashboard.log` (or
`$AAP_DEMO_DIR/dashboard.log`). For foreground debugging, run
`python3 dashboard/server.py --no-open`. Background mode does not install a
boot/login service.

### Resuming the demo

Run `aap-demo start` after stopping CRC, rebooting the host, or idling AAP. It:

1. Starts CRC and checks its filesystem usage. At **90% or higher**, it grows the
   existing VM disk by **20%**, rounded up to whole GiB, using a brief CRC
   stop/start. CRC expands the guest filesystem while preserving data and the PV
   reservation. Host free space is checked before resizing; no rebuild, forced
   shutdown, or deletion is performed.
2. Waits for the Kubernetes API and node readiness, restores CoreDNS routing, and
   recovers the AAP operator catalog.
3. Waits for installed networking, ingress, storage and OLM workloads; refreshes
   ingress CA trust using the existing local-development trust settings.
4. Resumes idle AAP through its custom resource, waits for workloads and operator
   reconciliation, and checks the gateway API.
5. Waits for enabled addons, starts preserved Fleet VMs, reapplies integrations,
   and checks workloads again before displaying status and the kubeconfig export.

Healthy application pods are not forcibly restarted. Disabled addons are not
enabled, missing deployments are not silently reinstalled, and failures return
nonzero with diagnostic guidance instead of reporting a ready demo.

The readiness timeout is **600 seconds per phase**, adjustable with
`AAP_START_TIMEOUT=900 aap-demo start`. Catalog recovery retains its separate
`AAP_START_CATALOG_TIMEOUT` setting. Disk checks run **during startup**, not in a
background monitoring service; there is no fixed 100 GiB free-space requirement.
They cover CRC's `/var` filesystem, not individual PVCs or a separately attached
persistent image-store disk. Interrupted disk growth retains its target for a
safe retry instead of repeatedly adding 20%.

### Automatic boot recovery

On Linux with CRC/libvirt, optionally install a system service that saves the
demo on graceful shutdown and restores the last completed backup on boot:

```bash
aap-demo service install             # Retain only the latest completed state
aap-demo service install --force-stop --stop-timeout 120  # Linux: opt in to crash-consistent CRC fallback
aap-demo service retention 3         # Optionally keep three states instead
aap-demo restart                     # Save, restore, and start the demo
```

This uses full cold backups of CRC/Fleet disks, configuration and required
keys/credentials. It briefly stops the demo for each backup and requires host
disk space. While enabled, `start`, `restart` and `stop` route through systemd.
Starting restores the saved state and brings the demo fully online; newer local
state can be replaced. See [shutdown backup and boot restore](docs/state-service.md)
for retention, security, recovery and disabling instructions.

`maintenance --apply` keeps running containers, images used by workloads,
namespaces, PVCs, and the optional local image cache. It also vacuums system
journals older than seven days and reports the VM disk space reclaimed.

`maintenance uninstall --apply` requires typing `UNINSTALL` and removes the CRC
cluster, Fleet VMs and images, CRC downloads, generated credentials and caches,
temporary swap, ingress trust entries, MCP/shell integration, CLI symlink, and
completions. It preserves the source repository and Red Hat pull secret. For
noninteractive use, also set `AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL`.

## Credential storage

aap-demo stores retained passwords and tokens under the `aap_demo` namespace in
the Ansible Vault-encrypted `~/.ansible/conf/env.yml`. The Vault password file is
`~/.ansible/conf/.vaultpass.txt`. Existing YAML keys outside `aap_demo` are
preserved, and older aap-demo Vault files are merged automatically. The
password file is generated automatically when absent. The directory is mode
`0700` and both files are mode `0600`.

Status, watch, deploy, and generated system-information output hide secrets by
default. Use `aap-demo status --show-secrets` only in an interactive terminal.
Keeping the encrypted Vault and its password in the same user-only directory
prevents accidental Git disclosure, but it does not protect against compromise
of the user account.

## Architecture

Architecture decisions are documented in [docs/adr/](docs/adr/README.md) (14 ADRs covering CLI
design, storage, OLM, addons, and cross-platform support).

### macOS / Linux / Windows

- **Networking:** SSH (2222), API (6443), HTTP/HTTPS (443) — all on localhost
- **Routes:** `*.apps.127.0.0.1.nip.io` (nip.io DNS, no /etc/hosts needed)
- **TLS:** MicroShift's ingress CA auto-trusted on macOS keychain / Linux ca-trust;
  on Windows, run `aap-demo deploy` from an elevated PowerShell (see
  [powershell/README.md](powershell/README.md#ingress-ca-and-browser-tls))

## Environment Variables

```bash
CRC_CPUS=8                   # VM CPU count (default: 8)
CRC_MEMORY=16384             # VM memory in MiB (default: 16384)
CRC_DISK=180                 # VM disk; minimum leaves 100 GiB for root/container images
CRC_PV_SIZE=70               # LVMS PV override; otherwise derived below CRC_DISK
NAMESPACE=aap-operator       # Target namespace
QUIET=true                   # Suppress disclaimer
```

## Troubleshooting

```bash
aap-demo diagnose      # Quick health check — finds common issues
aap-demo diagnose --ai # AI-powered analysis (requires claude CLI)
aap-demo must-gather   # Collect full diagnostics for support
```

On MicroShift 4.22+, `aap-demo deploy` relaxes container signature verification for
`registry.redhat.io` inside the CRC VM so operator index images can pull. This is a
**demo-only** workaround and must not be used as a production pattern.

## Clean Up

```bash
aap-demo clean         # Remove AAP (keep cluster)
aap-demo destroy       # Delete everything
./install.sh --uninstall  # Remove aap-demo CLI
```

## Documentation

- **[Full README](docs/FULL-README.md)** — Complete documentation, architecture, troubleshooting
- **[Architecture Decision Records](docs/adr/)** — Design decisions and rationale
- **[Contributing](docs/CONTRIBUTING.md)** — Development guidelines
- **[Linting](docs/LINTING.md)** — Ansible linting setup

### Versioning

Feature PRs do not need to change [`VERSION`](VERSION). Update it deliberately when preparing
a release; CI only verifies that the checked-in value is valid semver. Development builds are
also identified by the commit SHA and build timestamp shown by `aap-demo version`.

```bash
aap-demo version              # show current version + git build info
cz bump --increment PATCH     # after ./scripts/setup-linting.sh (optional)
```
