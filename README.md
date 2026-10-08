# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

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
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
./scripts/local-prereq.sh --full
```

On Linux x86_64, `--full` installs CRC when needed, installs `aap-demo`, creates and
deploys the local AAP environment, then enables MCP Server, APME, Product Demos, and
Automation Orchestrator. It automatically imports `~/Downloads/pull-secret.txt`; use
`--pull-secret /path/to/pull-secret.txt` when the download is elsewhere. Optional APME
GitHub integration can be configured later.

For the standard AAP and Automation Orchestrator installation without the additional
APME and Product Demos addons, use `./install.sh && aap-demo deploy`. The deploy command
prompts for the AO LLM provider and automatically enables its required addons.

`aap-demo create` provisions the MicroShift VM only. `aap-demo deploy` installs OLM, AAP,
and Automation Orchestrator (use `deploy` for the typical path; `create` alone is for
cluster-only setup).

Cluster credentials live at `~/.aap-demo/kubeconfig.microshift` and are **not** merged into
`~/.kube/config`. If you relied on the old default kubeconfig behavior, run:

```bash
export KUBECONFIG=~/.aap-demo/kubeconfig.microshift
# or: aap-demo kubeconfig   # refresh file and print export command
```

## Status

```bash
aap-demo version       # Tool version, commit, and build timestamp
aap-demo status        # Show routes and credentials
aap-demo preflight     # Read-only prerequisite and capacity checks
```

Run `aap-demo preflight` before a large deployment to check required tools,
Kubernetes connectivity, architecture, default and RWX storage, VM disk usage,
the AAP operator catalog, and scheduler-aware CPU and memory headroom. Capacity
shortfalls are warnings by default. Set `AAP_RESOURCE_PREFLIGHT_STRICT=true` to
make recommended CPU or memory shortfalls fail the command.

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

Credentials:
------------
  aap-operator: admin / <password>

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
aap-demo enable fleet        # Local QEMU managed nodes for AAP demos
aap-demo enable apme-eap     # Early Access Program only for APME
aap-demo enable local-cache  # Caches AAP containers locally so you don't re-download after destroy/create

# Ansible Product Demos - Official demo content from ansible/product-demos
aap-demo enable product-demos        # Five domains at once (includes base; Satellite opt-in)
aap-demo enable product-demo-satellite  # Satellite demos (requires a Satellite server)
aap-demo disable addon_name  # Disables addon
```

Fleet can keep the Red Hat Customer Portal offline token in the standard
Ansible Vault-encrypted MicroShift environment file:

```bash
aap-demo fleet auth          # Prompt once, store, and validate the token
aap-demo fleet auth status   # Validate the stored token without prompting
aap-demo fleet auth reset    # Remove the stored Red Hat token
```

The encrypted project environment file is `~/.ansible/conf/env-aap-demo.yml`,
and its Vault password file is `~/.ansible/conf/.vaultpass-aap-demo.txt`. Both are
created with owner-only permissions. Short-lived Red Hat access tokens are not
stored. Existing `env_microshift.yml` credentials are migrated automatically.

The Vault contains the Red Hat offline token, CDN username and password, Red Hat
account number, selected AAP subscription ID, project name, cluster name,
provider, and kubeconfig path. The RHSM image API uses the offline token.
When Fleet registration finds an unlicensed AAP instance, it uses the encrypted
portal credentials to list subscriptions for the stored account number and
attaches the selected subscription through AAP's subscription API. Credentials,
access tokens, and subscription responses are not printed or stored in plaintext.

Fleet can automatically download and cache entitled RHEL KVM images:

```bash
aap-demo fleet add 3 --image rhel9   # RHEL 9.8 x86_64 KVM
aap-demo fleet add 3 --image rhel10  # RHEL 10.2 x86_64 KVM
```

If no valid offline token is stored, Fleet opens the Red Hat API Tokens page and
prompts for the token. Fleet exchanges it for a short-lived access token, calls
the RHSM API `/management/v1/images/{sha256}/download`, and automatically uses
the returned entitled CDN URL. Signed URLs and short-lived tokens remain only
in memory and are never printed or stored. Downloads verify the published
SHA256 and QCOW2 format and are cached under `~/.aap-demo/fleet/images/`.

Fleet registers its nodes in the AAP `Fleet` inventory with the `Fleet SSH Key`
machine credential. If AAP has no subscription, Fleet automatically attaches the
stored selection before creating host records. If the account has multiple
eligible subscriptions and no prior selection, Fleet prompts for the subscription
ID and stores it encrypted. Register existing VMs without recreating them:

```bash
aap-demo fleet register
```

Fleet overlay disks are preserved by `aap-demo stop`. `aap-demo start`
automatically restarts them when the Fleet addon is enabled. They can also be
started explicitly without creating new nodes:

```bash
aap-demo fleet start
```

Automation Orchestrator does not connect to Fleet nodes directly. AO launches an
AAP job template through the auto-wired `aap-demo AAP` integration. To target
Fleet nodes, configure that AAP job template with the `Fleet` inventory and
`Fleet SSH Key` credential, then select the template in an AO **AAP job
template** workflow node. Re-run `aap-demo wire` if the AO AAP integration or
credential is missing.

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

For a complete rebuild, `aap-demo redeploy-all` saves the configured addon list,
destroys and recreates MicroShift, deploys AAP, reinstalls each saved addon in
dependency-safe order, and restores addon integrations. The command stops with an
error if any addon or wiring step cannot be restored. A configuration combining
APME with AO or Ollama requires at least 24 GiB of CRC memory; the command checks
this before destroying the existing cluster.

To manage the cache manually:

```bash
aap-demo enable local-cache load   # one-shot reload into fresh VM
aap-demo enable local-cache        # restore auto-load on future deploys
```

### Common Commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7 and Automation Orchestrator

# Cluster management
aap-demo status              # Show cluster status, routes, credentials
aap-demo stop                # Stop the cluster
aap-demo start               # Start the cluster and wait for the AAP catalog to recover
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
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Pull latest code and reinstall
aap-demo help                # Full command reference
```

## Architecture

Architecture decisions are documented in [docs/adr/](docs/adr/README.md), covering CLI
design, reliability, storage, OLM, addons, and cross-platform support.

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
CRC_DISK=100                 # VM disk size in GiB (default: 100)
CRC_PV_SIZE=70               # Storage reserved for LVMS PVCs in GiB (default: 70, must be < CRC_DISK)
NAMESPACE=aap-operator       # Target namespace
QUIET=true                   # Suppress disclaimer
AAP_RESOURCE_PREFLIGHT_STRICT=true  # Fail instead of warn when requested headroom is unavailable
AAP_RESOURCE_PREFLIGHT_SKIP=true    # Skip CPU/memory headroom checks
```

Mutating commands acquire `~/.aap-demo/operation.lock`, preventing concurrent lifecycle
or addon changes from racing. Stale locks are removed automatically when their owning
process no longer exists. Read-only commands such as `status` and `diagnose` do not lock.

Deployments and major addons report scheduler-aware CPU and memory headroom before
installation. Preflight warnings preserve existing behavior by default; set
`AAP_RESOURCE_PREFLIGHT_STRICT=true` when automation must reject insufficient capacity.

## Troubleshooting

```bash
aap-demo diagnose      # Quick health check — finds common issues
aap-demo diagnose --ai # AI-powered analysis (requires claude CLI)
aap-demo must-gather   # Collect full diagnostics for support
```

### Reset the AAP admin password

The local Ansible playbook securely prompts for a new password, updates the AAP
gateway account, and synchronizes the `aap-admin-password` Kubernetes secret:

```bash
ansible-playbook -i localhost, playbooks/reset-aap-admin-password.yml
```

The password must contain at least 12 characters. Override the namespace or
kubeconfig when the deployment does not use the defaults:

```bash
KUBECONFIG=/path/to/kubeconfig \
  ansible-playbook -i localhost, playbooks/reset-aap-admin-password.yml \
  -e aap_namespace=my-aap-namespace
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
