#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Repair MongoDB Windows service Error 1053 (service did not respond in time).

.DESCRIPTION
  Error 1053 almost always means mongod.exe exited before reporting SERVICE_RUNNING.
  Typical causes on MongoDB 8.x:
    - Invalid mongod.cfg YAML (tabs, bad indentation, stray "mp:", security with ";")
    - dbPath / logPath missing or not writable by NETWORK SERVICE
    - Oversized mongod.log
    - Stale mongod.lock after unclean shutdown
    - Broken service ImagePath quoting

  This script diagnoses, repairs config/paths/ACLs, reinstalls the service if needed,
  and starts MongoDB.

.PARAMETER MongoVersion
  Server version folder under Program Files (default: 8.3).

.PARAMETER DbPath
  WiredTiger data directory (default: C:\data\db).

.PARAMETER LogPath
  mongod log file path (default: C:\data\log\mongod.log).

.PARAMETER ServiceName
  Windows service name (default: MongoDB).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Fix-MongoDB-Service-1053.ps1
#>
[CmdletBinding()]
param(
    [string]$MongoVersion = "8.3",
    [string]$DbPath = "C:\data\db",
    [string]$LogPath = "C:\data\log\mongod.log",
    [string]$ServiceName = "MongoDB"
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnStep([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

$MongoRoot = "C:\Program Files\MongoDB\Server\$MongoVersion"
$MongoBin = Join-Path $MongoRoot "bin"
$MongodExe = Join-Path $MongoBin "mongod.exe"
$ConfigPath = Join-Path $MongoBin "mongod.cfg"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplateCfg = Join-Path $ScriptDir "mongod.cfg"

Write-Step "Preflight checks"
if (-not (Test-Path $MongodExe)) {
    Write-Fail "mongod.exe not found: $MongodExe"
    Write-Host "Install MongoDB Community $MongoVersion or pass -MongoVersion."
    exit 1
}
Write-Ok "Found $MongodExe"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-WarnStep "Service '$ServiceName' not found; will install after config repair."
}

Write-Step "Stop MongoDB service (if present)"
if ($svc -and $svc.Status -ne "Stopped") {
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Ok "Service stopped"
    }
    catch {
        Write-WarnStep "Stop-Service failed ($($_.Exception.Message)); continuing"
        & sc.exe stop $ServiceName | Out-Null
        Start-Sleep -Seconds 3
    }
}
else {
    Write-Ok "Service already stopped or not installed"
}

Write-Step "Ensure data/log directories exist"
$LogDir = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Force -Path $DbPath | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Write-Ok "dbPath=$DbPath"
Write-Ok "logPath=$LogPath"

Write-Step "Grant NETWORK SERVICE write access"
$aclTargets = @($DbPath, $LogDir)
foreach ($target in $aclTargets) {
    & icacls $target /grant "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)F" /T | Out-Null
    & icacls $target /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T | Out-Null
}
Write-Ok "ACL updated for NETWORK SERVICE and SYSTEM"

Write-Step "Clear stale lock / rotate huge log"
$lockFile = Join-Path $DbPath "mongod.lock"
if (Test-Path $lockFile) {
    $lockSize = (Get-Item $lockFile).Length
    if ($lockSize -eq 0) {
        Remove-Item $lockFile -Force
        Write-Ok "Removed empty mongod.lock"
    }
    else {
        Write-WarnStep "mongod.lock is non-empty ($lockSize bytes). Leaving it; unclean shutdown may need repair."
        Write-Host "  If start still fails, run: `"$MongodExe`" --dbpath `"$DbPath`" --repair"
    }
}

if (Test-Path $LogPath) {
    $logSizeMb = [math]::Round((Get-Item $LogPath).Length / 1MB, 1)
    if ($logSizeMb -gt 50) {
        $bak = "$LogPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Move-Item $LogPath $bak -Force
        Write-Ok "Rotated large log ($logSizeMb MB) -> $bak"
    }
    else {
        Write-Ok "Log size OK ($logSizeMb MB)"
    }
}

Write-Step "Backup and write corrected mongod.cfg"
if (Test-Path $ConfigPath) {
    $cfgBak = "$ConfigPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $ConfigPath $cfgBak -Force
    Write-Ok "Backed up existing config -> $cfgBak"

    $raw = Get-Content -Raw $ConfigPath
    if ($raw -match '(?m)^\s*mp:\s*$') {
        Write-WarnStep "Detected stray 'mp:' (common SNMP comment breakage) in old config"
    }
    if ($raw -match 'security\s*;') {
        Write-WarnStep "Detected 'security;' (must be 'security:') in old config"
    }
    if ($raw.Contains("`t")) {
        Write-WarnStep "Detected TAB characters in old config (YAML requires spaces)"
    }
}

$cfgContent = @"
# Generated by Fix-MongoDB-Service-1053.ps1
# Do not use tabs. Indent with two spaces.

storage:
  dbPath: $DbPath

systemLog:
  destination: file
  logAppend: true
  path: $LogPath

net:
  bindIp: 127.0.0.1,::1
  port: 27017
"@

if (Test-Path $TemplateCfg) {
    $template = Get-Content -Raw $TemplateCfg
    $template = $template -replace '(?m)^(\s*dbPath:\s*).+$', "`${1}$DbPath"
    $template = $template -replace '(?m)^(\s*path:\s*).+$', "`${1}$LogPath"
    # Keep only active (non-comment) security off by ensuring authorization stays commented in template
    $cfgContent = $template
    Write-Ok "Applied template: $TemplateCfg"
}
else {
    Write-WarnStep "Template mongod.cfg not found beside script; using embedded minimal config"
}

# Normalize: strip tabs; write UTF-8 without BOM (BOM can break mongod YAML parse)
$cfgContent = $cfgContent -replace "`t", "  "
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($ConfigPath, $cfgContent.TrimStart() + "`r`n", $utf8NoBom)
Write-Ok "Wrote $ConfigPath"
Write-Host $cfgContent

Write-Step "Foreground diagnosis (captures real mongod error if any)"
$diagLog = Join-Path $env:TEMP "mongod-1053-diag.log"
$diagErr = Join-Path $env:TEMP "mongod-1053-diag.err"
if (Test-Path $diagLog) { Remove-Item $diagLog -Force }
if (Test-Path $diagErr) { Remove-Item $diagErr -Force }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $MongodExe
$psi.Arguments = "--config `"$ConfigPath`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
$exitedEarly = $proc.WaitForExit(8000)
if (-not $exitedEarly) {
    # Still running after 8s => config likely OK
    $proc.Kill()
    [void]$proc.WaitForExit(3000)
    Write-Ok "mongod stayed up with this config (good sign)"
}
else {
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    Set-Content -Path $diagLog -Value $stdout
    Set-Content -Path $diagErr -Value $stderr
    Write-Fail "mongod exited during diagnosis (exit=$($proc.ExitCode))"
    if ($stderr) { Write-Host $stderr -ForegroundColor Red }
    if ($stdout) { Write-Host $stdout }
    Write-Host "Full output: $diagLog / $diagErr"
    Write-Host "Fix the reported error, then re-run this script."
    exit $proc.ExitCode
}

Write-Step "Ensure Windows service registration"
$binPath = "`"$MongodExe`" --config `"$ConfigPath`" --service"
$existing = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue

if ($existing) {
    $currentPath = $existing.PathName
    Write-Host "Current ImagePath: $currentPath"
    if ($currentPath -ne $binPath) {
        Write-WarnStep "ImagePath mismatch; rewriting service binary path"
        & sc.exe config $ServiceName binPath= $binPath | Out-Null
        & sc.exe config $ServiceName start= auto | Out-Null
        Write-Ok "Updated service binPath"
    }
    else {
        Write-Ok "Service ImagePath already correct"
    }
}
else {
    Write-Host "Installing service via mongod --install ..."
    & $MongodExe --config $ConfigPath --install --serviceName $ServiceName --serviceDisplayName "MongoDB Server ($MongoVersion)"
    if ($LASTEXITCODE -ne 0) {
        Write-WarnStep "mongod --install returned $LASTEXITCODE; trying sc.exe create"
        & sc.exe create $ServiceName binPath= $binPath DisplayName= "MongoDB Server ($MongoVersion)" start= auto
    }
    Write-Ok "Service installed"
}

& sc.exe config $ServiceName obj= "NT AUTHORITY\NetworkService" password= "" | Out-Null
Write-Ok "Service account set to NetworkService"

Write-Step "Start MongoDB service"
try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name $ServiceName
    if ($svc.Status -eq "Running") {
        Write-Ok "MongoDB service is Running"
    }
    else {
        Write-Fail "Service status: $($svc.Status)"
        if (Test-Path $LogPath) {
            Write-Host "---- last 40 log lines ----" -ForegroundColor Yellow
            Get-Content $LogPath -Tail 40
        }
        exit 1
    }
}
catch {
    Write-Fail "Start-Service failed: $($_.Exception.Message)"
    if (Test-Path $LogPath) {
        Write-Host "---- last 40 log lines ----" -ForegroundColor Yellow
        Get-Content $LogPath -Tail 40
    }
    Write-Host @"

Manual fallback:
  1) Run: `"$MongodExe`" --config `"$ConfigPath`"
  2) Read the console error / $LogPath
  3) Common follow-ups:
       - Port 27017 in use: netstat -ano | findstr :27017
       - Repair DB: `"$MongodExe`" --dbpath `"$DbPath`" --repair
       - VC++ runtime missing: install latest x64 Visual C++ Redistributable
"@
    exit 1
}

Write-Step "Quick connectivity check"
$mongosh = Join-Path $MongoBin "mongosh.exe"
$legacy = Join-Path $MongoBin "mongo.exe"
try {
    if (Test-Path $mongosh) {
        & $mongosh --quiet --eval "db.runCommand({ ping: 1 })" 2>$null
        Write-Ok "mongosh ping succeeded"
    }
    elseif (Test-Path $legacy) {
        & $legacy --quiet --eval "db.runCommand({ ping: 1 })" 2>$null
        Write-Ok "mongo ping succeeded"
    }
    else {
        $tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port 27017 -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Write-Ok "TCP 27017 is open (mongosh not installed)"
        }
        else {
            Write-WarnStep "Port 27017 not reachable yet; check $LogPath"
        }
    }
}
catch {
    Write-WarnStep "Connectivity check skipped: $($_.Exception.Message)"
}

Write-Host "`nDone. Config: $ConfigPath" -ForegroundColor Green
Write-Host "Data: $DbPath | Log: $LogPath"
exit 0
