# SCSI-3 Persistent Reservation Fencing Test

Validates SCSI-3 PR (Persistent Reservation) fencing on OpenShift Virtualization by running
a symmetric fence/unfence test loop across two VMs sharing a block LUN.

## What It Tests

The test exercises the full SCSI-3 PR fencing lifecycle used by cluster fencing agents
(e.g. `fence_scsi` in Pacemaker):

1. **Register** — both VMs register unique keys on the shared LUN
2. **Reserve** — both VMs race to acquire a type 5 (Write Exclusive, Registrants Only)
   reservation; the winner becomes the HOLDER, the loser becomes the VICTIM
3. **Steady-state** — verifies both registered VMs can write to the LUN
4. **Fence** — the HOLDER preempt-and-aborts the VICTIM's key
5. **Verify fencing** — confirms the VICTIM can no longer write (reservation conflict)
6. **Recovery** — the VICTIM re-registers and verifies write access is restored
7. **Cleanup** — all registrations and reservations are cleared

A random jitter sleep (0–500 ms) before the RESERVE means the reservation holder changes
unpredictably between iterations, exercising both code paths on both VMs.

## Prerequisites

- **OpenShift Virtualization** with `persistentReservation: true` feature gate enabled
  in the HyperConverged CR (already configured in this repo)
- **pr-helper** DaemonSet with `/run/udev` host mount (already configured via the
  `kubevirt.kubevirt.io/jsonpatch` annotation in `hyper-converged.yaml`)
- **Block-mode RWX storage** supporting SCSI-3 PR (e.g. `ontap-san` with iSCSI/FC)
- **sg3-utils** package inside the Linux VMs (installed automatically via cloud-init)
- **Windows Server 2019 golden image** DataSource (`win-server-2019`) in
  `openshift-virtualization-os-images` for the Windows VM test

## Infrastructure

This overlay deploys:

| Resource | Name | Description |
|----------|------|-------------|
| Namespace | `scsi3pr-test` | Isolated test namespace |
| **Linux (Fedora) VMs** | | |
| PVC | `pr-volume` | 10Gi RWX Block PVC on `ontap-san` |
| VirtualMachine | `scsi3pr-vm1` | Fedora VM with shared LUN + test script |
| VirtualMachine | `scsi3pr-vm2` | Fedora VM with shared LUN + test script |
| Secret | `raffa-key` | SSH public key for access |
| Service | `ssh-scsi3pr-vm1` | LoadBalancer for SSH to VM1 |
| Service | `ssh-scsi3pr-vm2` | LoadBalancer for SSH to VM2 |
| **Windows Server 2019 VMs** | | |
| PVC | `pr-volume-win` | 10Gi RWX Block PVC on `ontap-san` |
| VirtualMachine | `scsi3pr-win1` | Windows 2019 VM with shared LUN |
| VirtualMachine | `scsi3pr-win2` | Windows 2019 VM with shared LUN |
| ConfigMap | `scsi3pr-win-sysprep` | Sysprep unattend.xml (admin setup, WinRM, SSH) |
| Service | `rdp-scsi3pr-win1` | LoadBalancer for RDP + SSH to Win1 |
| Service | `rdp-scsi3pr-win2` | LoadBalancer for RDP + SSH to Win2 |

All VMs mount their shared PVC as a SCSI LUN with `reservation: true`, `shareable: true`,
and `errorPolicy: report`.

## Deploying

The overlay is applied via ArgoCD or directly with Kustomize:

```bash
oc apply -k clusters/etl7/overlays/scsi3pr-test/
```

Wait for both VMs to be running:

```bash
oc -n scsi3pr-test get vmi
```

## Running the Test

The test script is pre-installed at `/opt/scsi3pr-fence-test.sh` on both VMs via cloud-init.
Run it **simultaneously** on both VMs.

### Identify the shared LUN device

SSH into either VM and find the SCSI disk (typically `/dev/sda` — the non-root block device):

```bash
lsblk -d -o NAME,SIZE,TYPE,TRAN | grep disk
```

### Start the test on both VMs

Open two terminals (or use `virtctl console`):

**VM1:**
```bash
sudo /opt/scsi3pr-fence-test.sh \
  --device /dev/sda \
  --my-key 0xA001 \
  --peer-key 0xB002 \
  --duration 10m
```

**VM2** (simultaneously):
```bash
sudo /opt/scsi3pr-fence-test.sh \
  --device /dev/sda \
  --my-key 0xB002 \
  --peer-key 0xA001 \
  --duration 10m
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--device` | Yes | — | SCSI device path (e.g. `/dev/sda`) |
| `--my-key` | Yes | — | This VM's unique registration key (hex, e.g. `0xA001`) |
| `--peer-key` | Yes | — | The other VM's registration key (hex, e.g. `0xB002`) |
| `--duration` | Yes | — | Total runtime: `30s`, `10m`, `2h` |
| `--interval` | No | `5` | Seconds to pause between iterations |
| `--hostname` | No | `$(hostname)` | Label in log output |
| `--poll-timeout` | No | `30` | Seconds to wait for peer actions before failing |
| `--jitter-max` | No | `500` | Max random jitter (ms) before RESERVE attempt |

### Example Output

```
[scsi3pr-vm1 2026-09-17T14:05:23Z] === Iteration 1 (elapsed 0s / 600s) ===
  [PASS] Cleanup: LUN cleared
  [PASS] Register: key 0xA001 registered
  [INFO] Race: sleeping 237ms before reserve attempt...
  [INFO] Race: RESERVE succeeded — I am the HOLDER
  [PASS] Steady-state: my key 0xA001 registered
  [PASS] Steady-state: peer key 0xB002 registered
  [PASS] Steady-state: holder write succeeded
  [PASS] Fence: preempt-and-abort of 0xB002 succeeded
  [PASS] Verify: my key 0xA001 still registered
  [PASS] Verify: peer key 0xB002 removed
  [PASS] Verify: holder write after fence
  [PASS] Recovery: my key present
  [PASS] Recovery: peer re-registered
  [PASS] Recovery: holder write after recovery
  [PASS] Cleanup: end-of-iteration LUN cleared
  Iteration 1 completed in 6s (role: HOLDER)

=== SUMMARY (scsi3pr-vm1) ===
  Result:     PASS
  Iterations: 42 completed (23 as HOLDER, 19 as VICTIM)
  Duration:   597s / 600s budget
  Failures:   0
```

## How It Works (SCSI-3 PR Concepts)

### Reservation Type 5: Write Exclusive, Registrants Only

This is the standard fencing reservation type:
- All **registered** initiators (VMs) can read and write
- **Unregistered** initiators get `RESERVATION CONFLICT` on writes
- One initiator holds the reservation; the reservation protects the group

### Fencing via PREEMPT-AND-ABORT

When a node is considered failed, the surviving node issues:

```
PERSISTENT RESERVE OUT — PREEMPT AND ABORT
  param-rk  = my key (the surviving node)
  param-sark = victim key (the failed node)
  type = 5
```

This atomically:
1. Removes the victim's registration key
2. Aborts all pending SCSI tasks from the victim
3. Establishes a new reservation with the surviving node as holder

The victim immediately loses write access. This is how `fence_scsi` works in Pacemaker.

### Recovery

After the fenced node is repaired, it re-registers its key:

```
PERSISTENT RESERVE OUT — REGISTER
  param-sark = my key
```

Since the reservation is type 5 (registrants only), the newly-registered node immediately
regains write access without any action from the reservation holder.

## Troubleshooting

### "Device /dev/sda is not a block device"

The shared LUN may appear as a different device. Check with:
```bash
lsblk -S  # list SCSI devices
ls -la /dev/sd*
```

### "sg_persist not found"

The `sg3-utils` package was not installed by cloud-init. Install manually:
```bash
sudo dnf install -y sg3-utils
```

### "Never got fenced" / "Peer never registered"

The two VMs are not synchronized. Ensure:
- Both VMs are running (`oc -n scsi3pr-test get vmi`)
- Both scripts are started within a few seconds of each other
- The `--poll-timeout` is long enough (increase with `--poll-timeout 60`)

### Reservation conflict on REGISTER

A previous test run left dirty state. Clear manually:
```bash
sg_persist --in --read-keys /dev/sda
sg_persist --out --clear --param-rk=0xA001 /dev/sda
```

### Both VMs become HOLDER (should not happen)

This would indicate broken SCSI-3 PR support in the storage backend. The RESERVE command
should return `RESERVATION CONFLICT` if a reservation already exists. Check storage
vendor documentation for PR support.

---

## Windows Server 2019 Test

The same SCSI-3 PR fencing test runs on Windows VMs using a PowerShell script
(`scsi3pr-fence-test.ps1`) that issues identical SCSI CDBs via
`IOCTL_SCSI_PASS_THROUGH` (no external tools required — only built-in .NET / Win32 APIs).

### Windows VM Configuration

The Windows VMs (`scsi3pr-win1`, `scsi3pr-win2`) are cloned from the `win-server-2019`
golden image DataSource and include:
- **4 GiB RAM, 2 vCPUs** with Hyper-V enlightenments
- **Shared SCSI LUN** (`pr-volume-win`) with `reservation: true` and `errorPolicy: report`
- **Sysprep unattend.xml** that attempts to:
  - Set Administrator password to `R3dH@t2024!`
  - Enable auto-logon
  - Enable RDP and WinRM
  - Install and start OpenSSH Server

> **Note:** The sysprep only runs if the golden image was generalized (`sysprep /generalize`).
> If the image is a snapshot of a running system, the unattend.xml is ignored and the VM
> boots with whatever credentials were already configured.

### Deploying the PowerShell Script

The script is **not** embedded in the VMs (Windows has no cloud-init equivalent as reliable
as Linux). Copy it after the VMs boot.

**Option A — virtctl (if SSH is available):**

```bash
# Copy script to Windows VMs
virtctl -n scsi3pr-test scp clusters/etl7/overlays/scsi3pr-test/scsi3pr-fence-test.ps1 scsi3pr-win1:C:/Users/Administrator/scsi3pr-fence-test.ps1
virtctl -n scsi3pr-test scp clusters/etl7/overlays/scsi3pr-test/scsi3pr-fence-test.ps1 scsi3pr-win2:C:/Users/Administrator/scsi3pr-fence-test.ps1
```

**Option B — via RDP/VNC console:**

1. Open a console: `virtctl -n scsi3pr-test vnc scsi3pr-win1`
2. Copy-paste the script content into a PowerShell ISE window, or download it from a
   web-accessible location.

**Option C — via LoadBalancer SSH (if OpenSSH was installed by sysprep):**

```bash
# Get the LoadBalancer IPs
oc -n scsi3pr-test get svc rdp-scsi3pr-win1 rdp-scsi3pr-win2

# SCP the script
scp scsi3pr-fence-test.ps1 Administrator@<WIN1_LB_IP>:C:/Users/Administrator/
scp scsi3pr-fence-test.ps1 Administrator@<WIN2_LB_IP>:C:/Users/Administrator/
```

### Identify the Shared LUN

In a PowerShell prompt (Run as Administrator):

```powershell
# List disks to find the shared SCSI LUN
.\scsi3pr-fence-test.ps1 -ListDisks
```

Or manually:
```powershell
Get-Disk | Format-Table Number, OperationalStatus, @{L='Size(GB)';E={[math]::Round($_.Size/1GB,1)}}, FriendlyName, BusType
```

The shared LUN is the non-boot SCSI disk (typically `PhysicalDrive1`, ~10 GiB).

### Running the Windows Test

Open two PowerShell windows (as Administrator), one per VM:

**Win1:**
```powershell
.\scsi3pr-fence-test.ps1 -Device \\.\PhysicalDrive1 -MyKey 0xC001 -PeerKey 0xD002 -Duration 10m
```

**Win2** (simultaneously):
```powershell
.\scsi3pr-fence-test.ps1 -Device \\.\PhysicalDrive1 -MyKey 0xD002 -PeerKey 0xC001 -Duration 10m
```

> **Keys must be symmetric**: Win1's `-MyKey` = Win2's `-PeerKey` and vice versa.
> Use different keys (0xC001/0xD002) from the Linux VMs (0xA001/0xB002) to avoid
> confusion, even though they use a separate PVC.

### Windows-Specific Parameters

All parameters from the Linux version are supported as PowerShell named parameters:

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Device` | Yes | — | Physical drive path (e.g. `\\.\PhysicalDrive1`) |
| `-MyKey` | Yes | — | This VM's registration key (hex, e.g. `0xC001`) |
| `-PeerKey` | Yes | — | The other VM's registration key (hex, e.g. `0xD002`) |
| `-Duration` | Yes | — | Total runtime: `30s`, `10m`, `2h` |
| `-Interval` | No | `5` | Seconds between iterations |
| `-ListDisks` | No | — | List available physical drives and exit |

### Windows Troubleshooting

#### "CreateFile failed: Win32 error 5"
Access denied — the script must run as Administrator. Right-click PowerShell → "Run as Administrator".

#### "CreateFile failed: Win32 error 2"
The device path is wrong. Use `-ListDisks` to find the correct `\\.\PhysicalDriveN`.

#### Sysprep did not run / VM asks for OOBE
The golden image was not generalized. Log in with whatever credentials the image has,
then manually enable WinRM/SSH and copy the script.

#### Disk shows as "Offline" in Windows
The shared LUN may be set to offline by Windows SAN policy. Bring it online:
```powershell
Set-Disk -Number 1 -IsOffline $false
Set-Disk -Number 1 -IsReadOnly $false
```
**Do not** initialize or format the disk — it's a raw shared LUN.
