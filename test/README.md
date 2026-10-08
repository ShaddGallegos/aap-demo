# AAP Demo Test Suite

Validation tests for `aap-demo.sh` command-line interface.

## Usage

```bash
# Run the shell and Python test scripts used by CI
./test/test-core-commands.sh
./test/test-reliability-foundation.sh
./test/test-aap-readiness.sh
./test/test-cli-parsing.sh
./test/test-ingress-ca-export.sh
./test/test-fleet-auth.sh
./test/test-fleet-cli.sh
./test/test-fleet-images.sh
./test/test-fleet-aap.sh
./test/test-fleet-subscription.sh
./test/test-credential-vault-migration.sh
./test/test-addon-restore.sh
python3 ./test/test-ao-import-demos.py

# AAP provisioning fast-path test
python3 ./test/test-provision-aap-demos.py

# AO replica profile rendering (no cluster required)
./test/test-ao-replica-profile.sh
```

### Coverage

#### Help/Usage

- ✓ `help`, `-h`, `--help` output
- ✓ No args shows welcome banner

#### Argument Parsing

- ✓ `NAMESPACE`, `QUIET`, `FORCE` env vars
- ✓ Unknown commands error
- ✓ Unknown flags error
- ✓ `--context=NAME` / `--context NAME` parsing
- ✓ `--kubeconfig=PATH` error handling

#### Commands

- ✓ `config` (no args)
- ✓ `redhat-status`, `rh-status` (network skipped in quick mode)
- ✓ `idle [true|false]` arg parsing
- ✓ `idle notabool` shows error
- ✓ `diagnose` runs without cluster
- ✓ `diagnose --ai` flag parsing
- ✓ `enable` / `disable` (no args shows usage)
- ✓ `enable fake-addon` errors
- ✓ `deploy-all`, `redeploy-all` aliases recognized
- ✓ `must-gather [dir]` arg parsing
- The obsolete `aap-demo test` ATF command is intentionally not part of the CLI.
- ✓ `destroy`, `clean` show warnings (interactive skipped in quick mode)
- ✓ `destroy --reset` flag parsing
- ✓ AAP 2.7 terminal readiness across shell and PowerShell implementations

### Test Design

Tests validate:

1. **Argument parsing** — flags, env vars, positional args processed correctly
2. **Help text** — all help commands show usage
3. **Error handling** — unknown commands/args produce useful errors
4. **Non-destructive behavior** — tests don't modify cluster state
5. **Graceful degradation** — commands fail cleanly when cluster/AAP missing
6. **AO replica profile rendering** — default one-replica and explicit
   two-replica CR values, validation errors, and operator source-of-truth
   behavior
7. **Reliability foundation** — mutation lock contention and stale recovery,
   scheduler-aware resource accounting, strict preflight behavior, and shared
   Deployment readiness diagnostics
8. **Fault injection** — CRC start/stop failures, CoreDNS restoration failure,
   malformed Kubernetes JSON and quantities, and rollout failures return nonzero

### Live Idempotency

An opt-in live harness verifies that running the same command a second time does
not change normalized Kubernetes desired state:

```bash
AAP_DEMO_LIVE_IDEMPOTENCY=1 \
  ./test/test-live-idempotency.sh -- aap-demo wire
```

The explicit environment guard is required because the supplied command may mutate
the live cluster. The harness compares resource identity and `spec`, excluding status
and volatile metadata. It validates Kubernetes desired-state idempotency only; it
does not prove idempotency of every external AAP API side effect.

### Live Automation Orchestrator smoke test

The guarded, read-only AO smoke test verifies every JavaScript asset packaged in
the running UI pod is served with a JavaScript content type. It also authenticates
to the local AO and AAP APIs to verify the required integrations, all 10 imported
AO demo workflows, and all 17 AAP Orchestrator job templates:

```bash
AAP_DEMO_LIVE_AO_TEST=1 python3 test/test-ao-live-smoke.py
```

Credentials are read from the cluster's generated password secrets and are never
printed. The test does not create, update, launch, or delete automation content.

Tests **do not** validate:

- Actual cluster creation/destruction (would be destructive)
- Full deploy flow (too slow for unit tests)
- Live AAP operations (requires running instance)
- Network endpoints (skipped in `--quick` mode)

### Exit Codes

- **0** — All tests passed
- **1** — One or more tests failed

### Adding Tests

```bash
test_my_new_feature() {
  local output rc
  output=$(_run_aap_demo my-command arg 2>&1) && rc=0 || rc=$?

  if [ $rc -eq 0 ] && echo "$output" | grep -q "expected"; then
    _pass "my_new_feature"
  else
    _fail "my_new_feature" "reason here"
  fi
}

# Add to test execution section at bottom
test_my_new_feature
```

### Known Issues

- Tests may behave differently when cluster exists vs. doesn't exist
- Some commands (like `idle`, `status`) adapt to current cluster state
- Interactive prompts skipped via `QUIET=true` env var

## Live AO replica-profile clean lifecycle

Run this scenario on a disposable local MicroShift cluster to validate fresh
enable/disable behavior for both replica profiles. `AO_IMPORT_DEMOS=0` keeps
the scenario focused on AO installation and avoids importing demo workflows.

The ordinary disable command is intentional: it removes the AO namespace and
OLM resources while preserving the bootstrap credential and shared
CloudNativePG operator. Use the separate purge scenario below only when
irreversible database deletion is explicitly required.

```bash
# Start from a clean AO addon state.
./aap-demo.sh disable ao

# Default local profile: one backend, UI, and worker replica.
AO_IMPORT_DEMOS=0 ./aap-demo.sh enable ao
kubectl get automationorchestrator automation-orchestrator \
  -n automation-orchestrator \
  -o jsonpath='backend={.spec.backend.replicas} ui={.spec.ui.replicas} worker={.spec.worker.replicas} ready={.status.conditions[?(@.type=="Ready")].status} degraded={.status.conditions[?(@.type=="Degraded")].status}'
kubectl get deployments -n automation-orchestrator \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas'
./aap-demo.sh disable ao
kubectl get namespace automation-orchestrator  # expect NotFound

# Explicit higher-resource profile: two replicas each.
AO_LOW_RESOURCE=0 AO_IMPORT_DEMOS=0 ./aap-demo.sh enable ao
kubectl get automationorchestrator automation-orchestrator \
  -n automation-orchestrator \
  -o jsonpath='backend={.spec.backend.replicas} ui={.spec.ui.replicas} worker={.spec.worker.replicas} ready={.status.conditions[?(@.type=="Ready")].status} degraded={.status.conditions[?(@.type=="Degraded")].status}'
kubectl get deployments -n automation-orchestrator \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas'
./aap-demo.sh disable ao
kubectl get namespace automation-orchestrator  # expect NotFound
```

### Results (2026-09-24, local MicroShift)

- Default profile: `backend=1 ui=1 worker=1 ready=True degraded=False`; the
  backend, UI, and worker deployments each reported `DESIRED=1 READY=1`.
- Default disable: the `automation-orchestrator` namespace was removed.
- Two-replica profile: `backend=2 ui=2 worker=2 ready=True degraded=False`; the
  backend, UI, and worker deployments each reported `DESIRED=2 READY=2`.
- Final disable: the `automation-orchestrator` namespace was removed, leaving
  AO disabled and the repository worktree clean.

## Live AO clean-install regression scenario

Run this scenario on a disposable local `aap-demo` cluster to verify both the
purge option and first-install admin-password bootstrap. It is intentionally
not part of the default test suite because it deletes the AO database.

```bash
# Remove AO data, OLM resources, namespace, and saved bootstrap password.
CI=true ./aap-demo.sh disable ao --purge-data

# Confirm the local cached password is absent, then install normally.
test ! -e "$HOME/.aap-demo/ao/initial-admin-password"
CI=true ./aap-demo.sh enable ao
```

During the enable output, verify:

- `✓ Fresh AO admin password generated` appears before the instance is applied.
- `✓ Route ready` and `✓ Automation Orchestrator operator and instance applied`
  appear.
- The final instance has `READY=True` and `TLSREADY=True`:

```bash
kubectl get automationorchestrator automation-orchestrator \
  -n automation-orchestrator
kubectl get secret automation-orchestrator-initial-admin-password \
  -n automation-orchestrator
```
