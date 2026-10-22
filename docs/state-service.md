# Shutdown backups and boot restore

The optional `aap-demo.service` system service saves a cold backup of the local
demo on a graceful host shutdown and restores the latest completed backup before
bringing the demo online at boot.

This shutdown/boot feature is for **local development on Linux with CRC/libvirt**.
macOS and Windows instead have [explicit checkpoint/login recovery](#macos-and-windows-login-recovery).
It is not
a production backup system, a cross-machine migration tool, or a live-memory
snapshot.

## Install

Finish any running deployment or other mutating demo command first:

```bash
aap-demo service install
```

Installation requires sudo. It installs a root-owned runner and systemd unit,
enables the installing user's lingering user manager for CRC's sockets, stops
the demo, captures the initial baseline, restores it, and starts the demo.
The service is enabled for boot only after its initial start succeeds.

Allow enough time for cold disk copying, checksums, and AAP reconciliation.
The service allows one hour for startup and 30 minutes for shutdown. Adjust
these using `sudo systemctl edit aap-demo.service` if large disks require longer.
Shutdown can take several minutes because it includes a complete disk backup.
The repository must remain at its installation path.

### Optional forced CRC shutdown (Linux only)

If CRC repeatedly fails to shut down gracefully, explicitly opt in:

```bash
aap-demo service install --keep 1 --force-stop --stop-timeout 120
```

After the ordinary `crc stop` fails, the service waits up to another 120 seconds
(configurable from 1 to 86400). If CRC is still **running**, it force-powers-off
only the existing `crc` libvirt domain and verifies that CRC and Fleet are stopped
before copying disks. If CRC finishes shutting down during the wait, no force is
used. Unexpected VM states and libvirt errors stop recovery instead.

**Forced power-off can lose unsaved data.** The resulting backup is
**crash-consistent**, not a clean application backup; filesystem and application
recovery may be needed on restore. The service logs warnings and records
`crc_shutdown: forced` in the backup manifest, including a warning on restore.
Fleet guests are never force-stopped by this policy. Ordinary CLI stops and
macOS/Windows recovery behavior are unchanged.

The fallback is disabled unless `--force-stop` is supplied during installation.
An unsuccessful installation leaves automatic recovery disabled. Reinstall only
while the service is inactive, and verify a completed backup and successful
restore before relying on reboot recovery.

## Day-to-day commands

```bash
aap-demo start               # Save current state if active, then restore and start
aap-demo restart             # Save, restore, and bring the demo fully online
aap-demo stop                # Stop cleanly and publish a new backup
aap-demo service backup      # Explicit checkpoint followed by restore/start
aap-demo service status
aap-demo service backups
sudo journalctl -u aap-demo.service --no-pager
```

While enabled, top-level `start`, `restart`, and `stop` delegate to systemd.
The service runs CRC and addon commands as the installing user, not as root.
The root runner handles disk access, libvirt metadata, and private backup storage.
It refreshes CRC's user daemon after restoring its configuration. Interactive
ingress CA import is disabled for service-started commands; set up local browser
trust through the ordinary deployment/setup workflow before unattended use.
The existing demo operation lock prevents backup/restore from racing a deployment.
The service stops before libvirt and the user's CRC daemon on host shutdown.

**Automatic rollback is intentional:** starting an inactive service restores its
latest completed backup, replacing newer local changes in the managed state.
Restarting an active service first saves the current state, then restores that
new backup. A failed checksum check stops recovery rather than silently starting
from a corrupt or incomplete backup.

The demo is always brought fully online after restore, including resuming idle
AAP and enabled addons/Fleet. It does not preserve an intentional stopped or idle
mode across host reboot.

## Retention

Only **one completed backup** is retained by default:

```bash
aap-demo service install --keep 3    # Choose retention at installation
aap-demo service retention 3         # Change an existing installation
```

Retention changes apply when the next backup completes. A new backup is staged,
disk-checked and checksum-verified before it is published as `latest`; only then
are older completed backups pruned. Failure does not replace or delete the
previous completed backup.

Backups are stored under `/var/lib/aap-demo/<user>/states/`, outside the live
demo directories. Keep adequate **host** disk space: the preflight conservatively
requires approximately twice the allocated demo footprint free for staging.
Retained backups consume additional space. CRC's guest disk-growth policy does
not expand the host backup filesystem.

## What is saved

- CRC machine metadata, SSH keys, kubeconfigs, configuration and bundle cache.
- CRC's stopped disk, containing cluster objects, databases and local PVC data.
- File-backed additional CRC disks under the user's managed directories, such as
  an attached persistent image-store disk.
- Fleet disks, cloud-init data, configuration and SSH keys.
- The remaining persistent state under `~/.aap-demo/`.
- The libvirt domain definition and CRC's UEFI variable store.
- The standard credential Vault `~/.ansible/conf/env.yml` and its password file.

QCOW2 backing chains are flattened for active CRC and Fleet disks so their
backups do not depend on later changes to base images. Raw attached disks retain
their raw format. Stale Fleet PIDs, sockets, process locks and runtime logs are
not restored.

The credential Vault is copied as a **whole file**; restoring it also rolls back
any unrelated entries stored in that same file. Backups include secrets and the
Vault password, so they are **sensitive and not independently encrypted**. Backup
directories are root-only. Do not publish them or treat them as safe to share.

Only the standard local state directories and standard Vault paths are covered.
Custom credential locations, external storage, remote services, block-backed
VM disks, custom libvirt connections, and host configuration outside the listed
paths are not recoverable through this service. Unsupported attached disk paths
or formats cause backup failure rather than an incomplete success.

## Failure and recovery

- Fleet guests must respond to SSH and power off cleanly before backup. CRC must
  also stop cleanly unless the Linux forced-stop fallback is explicitly enabled.
  Fleet shutdown is scheduled with a short systemd timer so SSH can acknowledge
  the request before the guest disconnects.
- If CRC reports `VM Failed to gracefully shutdown`, backup stops without reading
  its running disk unless the opt-in fallback succeeds. A reproducible instance
  of this failure prevents clean-shutdown validation on the Fedora development
  host with CRC 2.64.0 / MicroShift
  4.22.13. Disable the failed service before resuming normal use; do not rely on
  automatic reboot recovery until a complete cold backup and restore succeeds.
  The opt-in fallback above can handle a stuck running CRC VM, but can lose
  unsaved data and does not establish clean-shutdown reliability.
- A sudden power loss cannot create a shutdown backup. The next boot uses the
  last **completed** backup, so changes since that checkpoint may be lost.
- An interrupted backup is never selected as `latest`. An interrupted restore
  can leave partially restored live files; the next attempt re-verifies and
  reapplies the same complete backup before starting any VM.
- Missing tools, insufficient disk space, concurrent demo operations, checksum
  errors and readiness failures fail the systemd job and are visible in its
  journal. A failed start is not reported as a ready demo.
- If a shutdown checkpoint fails during a manual restart, recovery is blocked
  for the remainder of that boot rather than rolling back newer local data to
  an older backup. Resolve the failure and run `aap-demo service backup` to retry
  the checkpoint. After an actual host reboot, the previous completed backup
  remains the recovery point.
- If installation fails, resolve the journal's error and rerun installation
  after other demo operations finish. The first successful start creates the
  initial baseline; an installation alone is not proof of recoverability.
- Updates to the installed root runner require reinstalling while the service
  is stopped. Do not replace its files during an active backup.

Disable the service before rebuilding, deleting or uninstalling the demo:

```bash
aap-demo service disable
```

This saves the active demo, stops it, and disables automatic boot restore.
Backups and the installed unit are retained; disabling does not erase your
recovery copies. With the service disabled, ordinary `aap-demo start` resumes
existing disks without rollback. Reinstall to re-enable backup/restore.

## macOS and Windows login recovery

These platforms use a different contract, explicitly **not** a guaranteed
shutdown hook or pre-login boot service:

1. Install recovery after a successful deployment.
2. Save with `aap-demo service backup` (resume afterward) or `aap-demo stop`
   (leave stopped) **before** a host restart/logout.
3. At the installing user's next login, restore the last completed checkpoint
   and bring the demo online.

`service install --keep N`, `service retention N`, `service status`,
`service backups`, `service backup`, and `service disable` are the platform
entry points. The default is one completed state. Starting stopped managed
disks intentionally replaces newer state with the last completed checkpoint.
Restarting a running managed demo checkpoints it first. A failed checkpoint
must not silently permit rollback over newer local work.

Large cold copies and VM shutdown cannot be guaranteed to finish within macOS
or Windows shutdown/logout deadlines. There is deliberately no claim that the
OS will wait. Abrupt shutdown may lose everything since the previous completed
checkpoint. Run an explicit checkpoint while your session is still available.

### macOS

The Bash CLI installs
`~/Library/LaunchAgents/com.aap-demo.recovery.plist` for the **next graphical
login**. It runs once, not as a continuously restarting supervisor. Logs,
retention settings and completed states are under
`~/Library/Application Support/aap-demo/`.

The supported CRC backend is vfkit with its local raw
`~/.crc/machines/crc/crc.img` and standard state paths. Legacy hyperkit,
external shared directories, externally linked top-level state/credential
paths and custom Vault paths are refused rather than partially backed up.
CRC must already have completed its ordinary host setup. Recovery refreshes
the existing `com.redhat.crc.daemon` LaunchAgent.

The checkpoint includes CRC metadata/cache/raw disk, `~/.aap-demo/`, managed
Fleet QCOW2 overlays flattened with `qemu-img`, and the standard Vault/password
files. It excludes runtime PID/socket/log/operation-lock files. Fleet guests
must shut down cleanly over SSH; there is no forced power-off.
Checksums are verified before publishing and before restore. Interrupted
restores are retryable and cannot be saved as a new checkpoint.

The private backup directory is owned by the user, not root. It contains
credentials and is **not separately encrypted**. Keep FileVault enabled.
Only same-account, same-path recovery is intended; use the same CRC version.
Disabling removes the login agent after checkpointing, not the retained copies.

### Windows

Use the native PowerShell CLI and Windows-hosted CRC, including when invoked
from WSL. Recovery uses a current-user login scheduled task and Hyper-V disk
handling; it does not install Linux systemd or run CRC inside WSL.
The installing user must belong to Hyper-V Administrators and have access
with a **limited**, non-elevated login token. The task
`aap-demo-login-restore` uses interactive current-user logon without storing a
password. Installation and checkpoint operations report missing access or
unsupported layouts rather than publish an incomplete snapshot.

Completed checkpoints are under
`%LOCALAPPDATA%\aap-demo\state\backups\`. The parent state directory also holds
the latest pointer, service configuration, pending/restore journals, logs
(last ten) and login result. Checkpoints include CRC machine disk/metadata,
`.crc\crc.json`, `.aap-demo\`, and the standard Vault/password files.
Restore staging uses `%USERPROFILE%\.aap-restore-<token>` on the same volume
as the files replaced.

**This is same-existing-VM checkpoint recovery, not full Hyper-V reconstruction.**
The Hyper-V VM definition must remain intact with the same VMId/configuration,
and the CRC bundle cache must remain present. Neither is recreated from the
checkpoint. Saved/paused VMs, Hyper-V checkpoints, differencing disks and
pass-through disks are refused. There is no automatic forced power-off.
Changing host hypervisor configuration outside these paths is not recoverable.
Budget approximately 1.1 times the managed disk footprint free for backup and
similar additional space for restore staging.

Backups are sensitive and not independently encrypted. Use Windows account
ACLs/BitLocker (files inherit the profile's ACLs), retain adequate host disk space, and do not share backup
directories. The workflow is same-machine recovery, not general VM migration.
See the [Windows quickstart](../Windows_Quickstart.md) and
[PowerShell guide](../powershell/README.md) for native prerequisites.

### Validation boundary

The new native integrations are covered by isolated filesystem/mock tests and
platform CI checks. **No real macOS/vfkit or Windows/Hyper-V backup/restore has
been validated from the Linux development host.** Before relying on recovery,
create a test value inside a disposable demo, checkpoint, restart/login and
verify that value, application readiness, credentials, addons and storage.
Do not treat a successful install or checksum test alone as recoverability.
