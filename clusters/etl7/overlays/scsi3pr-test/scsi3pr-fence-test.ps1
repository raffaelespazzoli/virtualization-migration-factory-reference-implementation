#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SCSI-3 Persistent Reservation fencing test for Windows VMs on OpenShift Virtualization.

.DESCRIPTION
    Runs the same script on TWO Windows VMs sharing a SCSI LUN. Each iteration
    both VMs register, race to reserve (type 5 — Write Exclusive, Registrants
    Only), then the winner fences the loser via PREEMPT-AND-ABORT. The loser
    detects fencing, re-registers, and both verify recovery.

    Uses raw SCSI passthrough (DeviceIoControl + IOCTL_SCSI_PASS_THROUGH)
    instead of sg_persist. The SCSI CDBs are identical to the Linux version.

    Prerequisites:
      - Run as Administrator
      - The shared LUN visible as \\.\PhysicalDriveN (use Get-Disk to find it)
      - Disk should NOT have mounted volumes (raw shared LUN)

.PARAMETER Device
    Path to the physical drive, e.g. \\.\PhysicalDrive1
    Use -ListDisks to see available drives.

.PARAMETER MyKey
    This VM's registration key in hex, e.g. 0xA001

.PARAMETER PeerKey
    The other VM's registration key in hex, e.g. 0xB002

.PARAMETER Duration
    How long to run, e.g. 30s, 10m, 2h

.PARAMETER Interval
    Pause between iterations in seconds (default: 5)

.PARAMETER Hostname
    Label for log output (default: computer name)

.PARAMETER PollTimeout
    Timeout in seconds for polling peer actions (default: 30)

.PARAMETER JitterMax
    Max random jitter in ms before RESERVE (default: 500)

.PARAMETER ListDisks
    List available physical disks and exit.

.EXAMPLE
    # List available disks first:
    .\scsi3pr-fence-test.ps1 -ListDisks

    # VM1:
    .\scsi3pr-fence-test.ps1 -Device \\.\PhysicalDrive1 -MyKey 0xA001 -PeerKey 0xB002 -Duration 10m

    # VM2:
    .\scsi3pr-fence-test.ps1 -Device \\.\PhysicalDrive1 -MyKey 0xB002 -PeerKey 0xA001 -Duration 10m
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [string]$Device,

    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [string]$MyKey,

    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [string]$PeerKey,

    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [string]$Duration,

    [Parameter(ParameterSetName = 'Run')]
    [int]$Interval = 5,

    [Parameter(ParameterSetName = 'Run')]
    [string]$Hostname = $env:COMPUTERNAME,

    [Parameter(ParameterSetName = 'Run')]
    [int]$PollTimeout = 30,

    [Parameter(ParameterSetName = 'Run')]
    [int]$JitterMax = 500,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListDisks
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# C# helper: raw SCSI passthrough via DeviceIoControl
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class ScsiPR : IDisposable
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(
        IntPtr hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize,
        IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);

    const uint GENERIC_READ       = 0x80000000;
    const uint GENERIC_WRITE      = 0x40000000;
    const uint FILE_SHARE_READ    = 1;
    const uint FILE_SHARE_WRITE   = 2;
    const uint OPEN_EXISTING      = 3;
    const uint IOCTL_SCSI_PASS_THROUGH = 0x0004D004;
    static readonly IntPtr INVALID = new IntPtr(-1);

    // SCSI_PASS_THROUGH layout depends on pointer size (ULONG_PTR DataBufferOffset)
    static readonly bool Is64       = IntPtr.Size == 8;
    static readonly int SPT_SIZE    = Is64 ? 56 : 44;
    static readonly int OFF_LEN     = 0;   // USHORT
    static readonly int OFF_STATUS  = 2;   // UCHAR ScsiStatus
    static readonly int OFF_CDBLEN  = 6;   // UCHAR CdbLength
    static readonly int OFF_SENSLEN = 7;   // UCHAR SenseInfoLength
    static readonly int OFF_DATAIN  = 8;   // UCHAR DataIn
    static readonly int OFF_DATAXLEN= 12;  // ULONG DataTransferLength
    static readonly int OFF_TIMEOUT = 16;  // ULONG TimeOutValue
    static readonly int OFF_DATAOFF = Is64 ? 24 : 20;  // ULONG_PTR DataBufferOffset
    static readonly int OFF_SENSOFF = Is64 ? 32 : 24;  // ULONG SenseInfoOffset
    static readonly int OFF_CDB     = Is64 ? 36 : 28;  // UCHAR Cdb[16]

    IntPtr handle = INVALID;
    string lastError = "";
    byte   lastScsiStatus = 0;

    public string LastError      { get { return lastError; } }
    public byte   LastScsiStatus { get { return lastScsiStatus; } }

    public bool Open(string path)
    {
        handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle == INVALID)
        {
            lastError = "CreateFile failed: Win32 error " + Marshal.GetLastWin32Error();
            return false;
        }
        return true;
    }

    public void Close()
    {
        if (handle != INVALID) { CloseHandle(handle); handle = INVALID; }
    }

    public void Dispose() { Close(); }

    // ---- Low-level SCSI passthrough ----

    bool SendSpt(byte[] cdb, int cdbLen, byte dataDir, byte[] dataOut, int dataLen,
                 out byte[] dataIn, out byte[] senseOut)
    {
        int senseLen    = 32;
        int senseOffset = SPT_SIZE;
        int dataOffset  = Align4(senseOffset + senseLen);
        int totalLen    = dataOffset + (dataLen > 0 ? dataLen : 0);
        if (totalLen < SPT_SIZE + senseLen) totalLen = SPT_SIZE + senseLen;

        IntPtr buf = Marshal.AllocHGlobal(totalLen);
        dataIn = null;
        senseOut = null;
        try
        {
            for (int i = 0; i < totalLen; i++) Marshal.WriteByte(buf, i, 0);

            // Fill header
            Marshal.WriteInt16(buf, OFF_LEN, (short)SPT_SIZE);
            Marshal.WriteByte(buf, OFF_CDBLEN, (byte)cdbLen);
            Marshal.WriteByte(buf, OFF_SENSLEN, (byte)senseLen);
            Marshal.WriteByte(buf, OFF_DATAIN, dataDir);
            Marshal.WriteInt32(buf, OFF_DATAXLEN, dataLen);
            Marshal.WriteInt32(buf, OFF_TIMEOUT, 30);
            if (Is64)
                Marshal.WriteInt64(buf, OFF_DATAOFF, (long)dataOffset);
            else
                Marshal.WriteInt32(buf, OFF_DATAOFF, dataOffset);
            Marshal.WriteInt32(buf, OFF_SENSOFF, senseOffset);

            // CDB
            for (int i = 0; i < cdbLen && i < 16; i++)
                Marshal.WriteByte(buf, OFF_CDB + i, cdb[i]);

            // Data out (for PR OUT, Write, etc.)
            if (dataOut != null && dataDir == 0)
            {
                for (int i = 0; i < dataOut.Length && i < dataLen; i++)
                    Marshal.WriteByte(buf, dataOffset + i, dataOut[i]);
            }

            uint bytesReturned;
            bool ok = DeviceIoControl(handle, IOCTL_SCSI_PASS_THROUGH,
                buf, (uint)totalLen, buf, (uint)totalLen, out bytesReturned, IntPtr.Zero);

            lastScsiStatus = Marshal.ReadByte(buf, OFF_STATUS);

            // Read sense data
            senseOut = new byte[senseLen];
            Marshal.Copy(buf + senseOffset, senseOut, 0, senseLen);

            if (!ok)
            {
                lastError = "DeviceIoControl failed: Win32 error " + Marshal.GetLastWin32Error();
                return false;
            }

            if (lastScsiStatus == 0x18)
            {
                lastError = "reservation conflict";
                return false;
            }

            if (lastScsiStatus != 0)
            {
                byte sk  = (byte)(senseOut[2] & 0x0F);
                byte asc = senseOut[12];
                byte ascq = senseOut[13];
                lastError = String.Format("SCSI status 0x{0:X2} SK=0x{1:X} ASC=0x{2:X2} ASCQ=0x{3:X2}",
                    lastScsiStatus, sk, asc, ascq);
                return false;
            }

            // Data in (for PR IN, etc.)
            if (dataDir == 1 && dataLen > 0)
            {
                dataIn = new byte[dataLen];
                Marshal.Copy(buf + dataOffset, dataIn, 0, dataLen);
            }

            lastError = "";
            return true;
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    static int Align4(int v) { return (v + 3) & ~3; }

    // ---- PR IN commands ----

    public byte[] PrInReadKeys()
    {
        byte[] cdb = new byte[10];
        cdb[0] = 0x5E;  // PERSISTENT RESERVE IN
        cdb[1] = 0x00;  // READ KEYS
        int allocLen = 512;
        cdb[7] = (byte)((allocLen >> 8) & 0xFF);
        cdb[8] = (byte)(allocLen & 0xFF);

        byte[] dataIn, sense;
        if (!SendSpt(cdb, 10, 1, null, allocLen, out dataIn, out sense))
            return null;
        return dataIn;
    }

    public byte[] PrInReadReservation()
    {
        byte[] cdb = new byte[10];
        cdb[0] = 0x5E;
        cdb[1] = 0x01;  // READ RESERVATION
        int allocLen = 256;
        cdb[7] = (byte)((allocLen >> 8) & 0xFF);
        cdb[8] = (byte)(allocLen & 0xFF);

        byte[] dataIn, sense;
        if (!SendSpt(cdb, 10, 1, null, allocLen, out dataIn, out sense))
            return null;
        return dataIn;
    }

    public byte[] PrInReportCapabilities()
    {
        byte[] cdb = new byte[10];
        cdb[0] = 0x5E;
        cdb[1] = 0x02;  // REPORT CAPABILITIES
        int allocLen = 256;
        cdb[7] = (byte)((allocLen >> 8) & 0xFF);
        cdb[8] = (byte)(allocLen & 0xFF);

        byte[] dataIn, sense;
        if (!SendSpt(cdb, 10, 1, null, allocLen, out dataIn, out sense))
            return null;
        return dataIn;
    }

    // ---- PR OUT commands ----

    public bool PrOut(byte serviceAction, byte prType, ulong reservationKey, ulong serviceActionKey)
    {
        byte[] cdb = new byte[10];
        cdb[0] = 0x5F;  // PERSISTENT RESERVE OUT
        cdb[1] = serviceAction;
        cdb[2] = prType; // Type in lower 4 bits, Scope (0) in upper 4 bits
        int paramLen = 24;
        cdb[7] = (byte)((paramLen >> 8) & 0xFF);
        cdb[8] = (byte)(paramLen & 0xFF);

        byte[] paramData = new byte[24];
        WriteBE64(paramData, 0, reservationKey);
        WriteBE64(paramData, 8, serviceActionKey);

        byte[] dataIn, sense;
        return SendSpt(cdb, 10, 0, paramData, paramLen, out dataIn, out sense);
    }

    // Convenience wrappers
    public bool Register(ulong newKey)           { return PrOut(0x00, 0, 0, newKey); }
    public bool Unregister(ulong currentKey)     { return PrOut(0x00, 0, currentKey, 0); }
    public bool Reserve(ulong myKey)             { return PrOut(0x01, 0x05, myKey, 0); }
    public bool Release(ulong myKey)             { return PrOut(0x02, 0x05, myKey, 0); }
    public bool Clear(ulong myKey)               { return PrOut(0x03, 0, myKey, 0); }
    public bool PreemptAbort(ulong myKey, ulong victimKey) { return PrOut(0x05, 0x05, myKey, victimKey); }

    // ---- Test Unit Ready ----

    public bool TestUnitReady()
    {
        byte[] cdb = new byte[6]; // TUR opcode = 0x00, all zeros
        byte[] dataIn, sense;
        return SendSpt(cdb, 6, 2, null, 0, out dataIn, out sense);
    }

    // ---- Write test (512 bytes of zeros to LBA 0) ----

    public bool WriteTest()
    {
        byte[] cdb = new byte[10];
        cdb[0] = 0x2A;  // WRITE(10)
        // LBA 0 (bytes 2-5 = 0)
        cdb[8] = 0x01;  // Transfer length = 1 block

        byte[] data = new byte[512]; // all zeros
        byte[] dataIn, sense;
        return SendSpt(cdb, 10, 0, data, 512, out dataIn, out sense);
    }

    // ---- Response parsing helpers ----

    public static ulong[] ParseReadKeys(byte[] data)
    {
        if (data == null || data.Length < 8) return new ulong[0];
        uint addLen = ReadBE32(data, 4);
        int count = (int)(addLen / 8);
        ulong[] keys = new ulong[count];
        for (int i = 0; i < count && (8 + i * 8 + 8) <= data.Length; i++)
            keys[i] = ReadBE64(data, 8 + i * 8);
        return keys;
    }

    public static ulong ParseReservationKey(byte[] data)
    {
        if (data == null || data.Length < 16) return 0;
        uint addLen = ReadBE32(data, 4);
        if (addLen == 0) return 0;
        return ReadBE64(data, 8);
    }

    // ---- Byte helpers (SCSI = big-endian) ----

    static void WriteBE64(byte[] buf, int off, ulong val)
    {
        for (int i = 0; i < 8; i++)
            buf[off + i] = (byte)((val >> (56 - i * 8)) & 0xFF);
    }

    static ulong ReadBE64(byte[] data, int off)
    {
        ulong v = 0;
        for (int i = 0; i < 8; i++) v = (v << 8) | data[off + i];
        return v;
    }

    static uint ReadBE32(byte[] data, int off)
    {
        return ((uint)data[off] << 24) | ((uint)data[off+1] << 16) |
               ((uint)data[off+2] << 8) | data[off+3];
    }
}
"@ -Language CSharp

# ---------------------------------------------------------------------------
# List disks mode
# ---------------------------------------------------------------------------
if ($ListDisks) {
    Write-Host "`nAvailable physical disks:`n"
    Get-Disk | Format-Table -AutoSize Number,
        @{L='Status';E={$_.OperationalStatus}},
        @{L='Size(GB)';E={[math]::Round($_.Size/1GB,1)}},
        FriendlyName,
        @{L='BusType';E={$_.BusType}},
        @{L='DevicePath';E={"\\.\PhysicalDrive$($_.Number)"}}
    Write-Host "Use -Device '\\.\PhysicalDriveN' where N is the disk number.`n"
    exit 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function ConvertFrom-HexKey([string]$hex) {
    $hex = $hex.Trim()
    if ($hex.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
        $hex = $hex.Substring(2)
    }
    [Convert]::ToUInt64($hex, 16)
}

function ConvertTo-Seconds([string]$val) {
    if ($val -match '^(\d+)\s*([smhSMH]?)$') {
        $num = [int]$Matches[1]
        switch ($Matches[2].ToLower()) {
            's' { return $num }
            ''  { return $num }
            'm' { return $num * 60 }
            'h' { return $num * 3600 }
        }
    }
    throw "Invalid duration format: $val (use e.g. 30s, 10m, 2h)"
}

function Get-EpochSecs { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Get-Timestamp { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Format-Key([uint64]$key) { '0x{0:X}' -f $key }

# Color helpers
function Write-Pass  { param([string]$msg) Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail  { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-Info  { param([string]$msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Hdr   { param([int]$iter, [int]$elapsed, [int]$budget)
    Write-Host "`n[$script:Label $(Get-Timestamp)] === Iteration $iter (elapsed ${elapsed}s / ${budget}s) ===" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
[uint64]$script:MyKeyVal   = ConvertFrom-HexKey $MyKey
[uint64]$script:PeerKeyVal = ConvertFrom-HexKey $PeerKey
[int]$script:DurationSecs  = ConvertTo-Seconds $Duration
[string]$script:Label      = $Hostname

# Counters
[int]$script:Iteration       = 0
[int]$script:Failures        = 0
[int]$script:HolderCount     = 0
[int]$script:VictimCount     = 0
[int]$script:LastIterSecs    = 30

# ---------------------------------------------------------------------------
# Open device
# ---------------------------------------------------------------------------
$script:pr = New-Object ScsiPR

# ---------------------------------------------------------------------------
# PR wrapper functions
# ---------------------------------------------------------------------------
function Test-KeyRegistered([uint64]$key) {
    $data = $script:pr.PrInReadKeys()
    if ($null -eq $data) { return $false }
    $keys = [ScsiPR]::ParseReadKeys($data)
    $hexTarget = '{0:x}' -f $key
    foreach ($k in $keys) {
        if (('{0:x}' -f $k) -eq $hexTarget) { return $true }
    }
    return $false
}

function Get-RegisteredKeys {
    $data = $script:pr.PrInReadKeys()
    if ($null -eq $data) { return @() }
    return [ScsiPR]::ParseReadKeys($data)
}

function Get-ReservationHolder {
    $data = $script:pr.PrInReadReservation()
    if ($null -eq $data) { return [uint64]0 }
    return [ScsiPR]::ParseReservationKey($data)
}

# ---------------------------------------------------------------------------
# Cleanup helpers
# ---------------------------------------------------------------------------
function Invoke-FullCleanup {
    $script:pr.Clear($script:MyKeyVal)   | Out-Null
    $script:pr.Clear($script:PeerKeyVal) | Out-Null
    $script:pr.Unregister($script:MyKeyVal)   | Out-Null
    $script:pr.Unregister($script:PeerKeyVal) | Out-Null
}

function Invoke-SelfCleanup {
    $script:pr.Release($script:MyKeyVal)    | Out-Null
    $script:pr.Unregister($script:MyKeyVal) | Out-Null
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
function Assert-KeyRegistered([uint64]$key, [string]$desc) {
    if (Test-KeyRegistered $key) {
        Write-Pass $desc
        return $true
    } else {
        Write-Fail $desc
        Write-Fail "  Key $(Format-Key $key) not found in registered keys"
        $keys = Get-RegisteredKeys
        Write-Fail "  Keys: $($keys | ForEach-Object { Format-Key $_ })"
        $script:Failures++
        return $false
    }
}

function Assert-WriteSucceeds([string]$desc) {
    if ($script:pr.WriteTest()) {
        Write-Pass $desc
        return $true
    } else {
        Write-Fail $desc
        Write-Fail "  Write error: $($script:pr.LastError)"
        $script:Failures++
        return $false
    }
}

function Assert-WriteFails([string]$desc) {
    if ($script:pr.WriteTest()) {
        Write-Fail $desc
        Write-Fail "  Write unexpectedly succeeded"
        $script:Failures++
        return $false
    } else {
        Write-Pass $desc
        return $true
    }
}

# ---------------------------------------------------------------------------
# Poll helper
# ---------------------------------------------------------------------------
function Wait-Until([string]$desc, [int]$timeoutSecs, [scriptblock]$condition) {
    $deadline = (Get-EpochSecs) + $timeoutSecs
    while ((Get-EpochSecs) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Seconds 1
    }
    Write-Fail "Timeout (${timeoutSecs}s) waiting for: $desc"
    return $false
}

# ---------------------------------------------------------------------------
# HOLDER path
# ---------------------------------------------------------------------------
function Invoke-HolderPath {
    Write-Info "Holder: waiting for peer key $(Format-Key $script:PeerKeyVal) to appear..."
    if (-not (Wait-Until "peer registers key $(Format-Key $script:PeerKeyVal)" $PollTimeout {
        Test-KeyRegistered $script:PeerKeyVal
    })) {
        Write-Fail "Peer never registered key $(Format-Key $script:PeerKeyVal)"
        return $false
    }

    if (-not (Assert-KeyRegistered $script:MyKeyVal   "Steady-state: my key $(Format-Key $script:MyKeyVal) registered")) { return $false }
    if (-not (Assert-KeyRegistered $script:PeerKeyVal "Steady-state: peer key $(Format-Key $script:PeerKeyVal) registered")) { return $false }
    if (-not (Assert-WriteSucceeds "Steady-state: holder write succeeded")) { return $false }

    Start-Sleep -Seconds 2

    # Fence: preempt-and-abort the peer
    if ($script:pr.PreemptAbort($script:MyKeyVal, $script:PeerKeyVal)) {
        Write-Pass "Fence: preempt-and-abort of $(Format-Key $script:PeerKeyVal) succeeded"
    } else {
        Write-Fail "Fence: preempt-and-abort of $(Format-Key $script:PeerKeyVal) failed"
        Write-Fail "  Error: $($script:pr.LastError)"
        $script:Failures++
        return $false
    }

    if (-not (Assert-KeyRegistered $script:MyKeyVal "Verify: my key $(Format-Key $script:MyKeyVal) still registered")) { return $false }
    if (-not (Assert-WriteSucceeds "Verify: holder write after fence succeeded")) { return $false }

    # Wait for peer to re-register
    Write-Info "Holder: waiting for peer to re-register..."
    if (-not (Wait-Until "peer re-registers key $(Format-Key $script:PeerKeyVal)" $PollTimeout {
        Test-KeyRegistered $script:PeerKeyVal
    })) {
        Write-Fail "Peer never re-registered key $(Format-Key $script:PeerKeyVal) after fencing"
        return $false
    }

    Write-Pass "Recovery: peer key $(Format-Key $script:PeerKeyVal) re-registered"
    if (-not (Assert-WriteSucceeds "Recovery: holder write after recovery succeeded")) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# VICTIM path
# ---------------------------------------------------------------------------
function Invoke-VictimPath {
    Write-Info "Victim: waiting for peer key $(Format-Key $script:PeerKeyVal) to appear..."
    if (-not (Wait-Until "peer registers key $(Format-Key $script:PeerKeyVal)" $PollTimeout {
        Test-KeyRegistered $script:PeerKeyVal
    })) {
        Write-Fail "Peer never registered key $(Format-Key $script:PeerKeyVal)"
        return $false
    }

    if (-not (Assert-KeyRegistered $script:MyKeyVal   "Steady-state: my key $(Format-Key $script:MyKeyVal) registered")) { return $false }
    if (-not (Assert-KeyRegistered $script:PeerKeyVal "Steady-state: peer key $(Format-Key $script:PeerKeyVal) registered")) { return $false }
    if (-not (Assert-WriteSucceeds "Steady-state: victim write succeeded (both registered)")) { return $false }

    # Wait to be fenced
    Write-Info "Victim: waiting to be fenced (key $(Format-Key $script:MyKeyVal) removed)..."
    if (-not (Wait-Until "my key $(Format-Key $script:MyKeyVal) removed by holder" $PollTimeout {
        -not (Test-KeyRegistered $script:MyKeyVal)
    })) {
        Write-Fail "Never got fenced - my key $(Format-Key $script:MyKeyVal) was not removed within ${PollTimeout}s"
        return $false
    }
    Write-Pass "Fenced: my key $(Format-Key $script:MyKeyVal) was removed by peer"

    if (-not (Assert-WriteFails "Fenced: write correctly blocked (reservation conflict)")) { return $false }

    # Re-register
    if ($script:pr.Register($script:MyKeyVal)) {
        Write-Pass "Recovery: re-registered key $(Format-Key $script:MyKeyVal)"
    } else {
        Write-Fail "Recovery: failed to re-register key $(Format-Key $script:MyKeyVal)"
        Write-Fail "  Error: $($script:pr.LastError)"
        $script:Failures++
        return $false
    }

    if (-not (Assert-WriteSucceeds "Recovery: write succeeds after re-registration")) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Single iteration
# ---------------------------------------------------------------------------
function Invoke-Iteration {
    $iterStart = Get-EpochSecs

    # Self-cleanup
    Invoke-SelfCleanup
    Start-Sleep -Seconds 2
    Write-Pass "Cleanup: my key unregistered"

    # Register
    if ($script:pr.Register($script:MyKeyVal)) {
        Write-Pass "Register: key $(Format-Key $script:MyKeyVal) registered"
    } else {
        Write-Fail "Register: failed to register key $(Format-Key $script:MyKeyVal)"
        Write-Fail "  Error: $($script:pr.LastError)"
        $script:Failures++
        return $false
    }

    # Random jitter then race
    $jitterMs = Get-Random -Minimum 0 -Maximum ($JitterMax + 1)
    Write-Info "Race: sleeping ${jitterMs}ms before reserve attempt..."
    Start-Sleep -Milliseconds $jitterMs

    $role = ''
    if ($script:pr.Reserve($script:MyKeyVal)) {
        Write-Info "Race: RESERVE succeeded - I am the HOLDER"
        $role = 'HOLDER'
        $script:HolderCount++
    } else {
        if ($script:pr.LastError -match 'reservation conflict') {
            Write-Info "Race: RESERVE got conflict - I am the VICTIM"
            $role = 'VICTIM'
            $script:VictimCount++
        } else {
            Write-Fail "Race: RESERVE failed with unexpected error"
            Write-Fail "  Error: $($script:pr.LastError)"
            $script:Failures++
            return $false
        }
    }

    # Run role path
    $ok = if ($role -eq 'HOLDER') { Invoke-HolderPath } else { Invoke-VictimPath }
    if (-not $ok) { return $false }

    $script:LastIterSecs = (Get-EpochSecs) - $iterStart
    Write-Host "  Iteration $($script:Iteration) completed in $($script:LastIterSecs)s (role: $role)"
    return $true
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Invoke-Preflight {
    Write-Host "=== Preflight Checks ==="

    if (-not $script:pr.Open($Device)) {
        Write-Fail "Cannot open device $Device : $($script:pr.LastError)"
        Write-Host ""
        Write-Host "Available disks:"
        Get-Disk | Format-Table Number, @{L='Size(GB)';E={[math]::Round($_.Size/1GB,1)}}, FriendlyName
        exit 1
    }
    Write-Pass "Device $Device opened successfully"

    if (-not $script:pr.TestUnitReady()) {
        Write-Fail "Device $Device failed Test Unit Ready: $($script:pr.LastError)"
        exit 1
    }
    Write-Pass "Device $Device passed Test Unit Ready"

    $caps = $script:pr.PrInReportCapabilities()
    if ($null -ne $caps -and $caps.Length -ge 4) {
        Write-Pass "Device supports Persistent Reservations"
    } else {
        Write-Info "Could not confirm PR capabilities (non-fatal): $($script:pr.LastError)"
    }

    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    Invoke-Preflight

    $startTime = Get-EpochSecs
    $estIterTime = 30

    Write-Host "=== Starting SCSI-3 PR Fencing Test ==="
    Write-Host "  Device:    $Device"
    Write-Host "  My key:    $(Format-Key $script:MyKeyVal)"
    Write-Host "  Peer key:  $(Format-Key $script:PeerKeyVal)"
    Write-Host "  Duration:  $($script:DurationSecs)s"
    Write-Host "  Interval:  ${Interval}s"
    Write-Host "  Hostname:  $script:Label"
    Write-Host ""

    while ($true) {
        $now = Get-EpochSecs
        $elapsed = $now - $startTime
        $remaining = $script:DurationSecs - $elapsed

        # Safety margin: est + 5s so both VMs stop around the same time
        $minRemaining = $estIterTime + 5
        if ($remaining -lt $minRemaining) {
            Write-Host "Not enough time remaining (${remaining}s < ${minRemaining}s). Stopping."
            break
        }

        $script:Iteration++
        Write-Hdr $script:Iteration $elapsed $script:DurationSecs

        $ok = Invoke-Iteration

        if ((-not $ok) -or ($script:Failures -gt 0)) {
            Write-Host ""
            Write-Host "=== FAILED at iteration $($script:Iteration) ===" -ForegroundColor Red
            Write-Host "  Elapsed:    ${elapsed}s / $($script:DurationSecs)s"
            Write-Host "  Failures:   $($script:Failures)"
            Write-Host "  Holder:     $($script:HolderCount) times"
            Write-Host "  Victim:     $($script:VictimCount) times"
            Invoke-FullCleanup
            $script:pr.Close()
            exit 1
        }

        $estIterTime = $script:LastIterSecs

        if ($Interval -gt 0) { Start-Sleep -Seconds $Interval }
    }

    $totalElapsed = (Get-EpochSecs) - $startTime
    Write-Host ""
    Write-Host "=== SUMMARY ($script:Label) ===" -ForegroundColor Green
    Write-Host "  Result:     PASS"
    Write-Host "  Iterations: $($script:Iteration) completed ($($script:HolderCount) as HOLDER, $($script:VictimCount) as VICTIM)"
    Write-Host "  Duration:   ${totalElapsed}s / $($script:DurationSecs)s budget"
    Write-Host "  Failures:   0"

    Invoke-FullCleanup
    $script:pr.Close()
    exit 0
}

# Register cleanup on Ctrl+C / script exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    if ($null -ne $script:pr) {
        Invoke-FullCleanup
        $script:pr.Close()
    }
} | Out-Null

try {
    Main
} catch {
    Write-Host ""
    Write-Host "FATAL ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    if ($null -ne $script:pr) {
        Invoke-FullCleanup
        $script:pr.Close()
    }
    exit 1
}
