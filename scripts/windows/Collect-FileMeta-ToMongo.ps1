#Requires -Version 5.1
<#
.SYNOPSIS
  Scan the OS for files modified in the last N hours and upsert their metadata into MongoDB.

.DESCRIPTION
  Enumerates configured drive roots, collects metadata for files whose LastWriteTime
  falls within the lookback window (default 24 hours), and upserts documents into a
  MongoDB collection keyed by fullPath.

  Intended to run under Windows Task Scheduler once every 24 hours
  (see Register-FileMetaCollector-Task.ps1).

.PARAMETER Roots
  Filesystem roots to scan. Default: all ready fixed local drives (e.g. C:\).

.PARAMETER LookbackHours
  Only files with LastWriteTime >= now - LookbackHours are collected (default 24).

.PARAMETER MongoUri
  MongoDB connection URI (default mongodb://127.0.0.1:27017).

.PARAMETER Database
  Target database name (default: filemonitor).

.PARAMETER Collection
  Target collection name (default: file_meta).

.PARAMETER ExcludePathPatterns
  Path substrings to skip (case-insensitive -like match).

.PARAMETER DryRun
  Collect and write a JSONL preview without touching MongoDB.

.PARAMETER OutJsonl
  Optional path for the JSONL payload (default under $env:TEMP).

.PARAMETER BatchSize
  Documents per mongosh bulkWrite batch (default 500).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Collect-FileMeta-ToMongo.ps1

.EXAMPLE
  .\Collect-FileMeta-ToMongo.ps1 -Roots 'C:\Users' -LookbackHours 24 -DryRun
#>
[CmdletBinding()]
param(
    [string[]]$Roots = @(),
    [ValidateRange(1, 8760)]
    [int]$LookbackHours = 24,
    [string]$MongoUri = "mongodb://127.0.0.1:27017",
    [string]$Database = "filemonitor",
    [string]$Collection = "file_meta",
    [string[]]$ExcludePathPatterns = @(
        '\System Volume Information',
        '\$Recycle.Bin',
        '\Windows\WinSxS',
        '\Windows\SoftwareDistribution',
        '\Windows\Temp',
        '\Windows\CSC',
        '\Recovery',
        '\ProgramData\Microsoft\Windows Defender',
        '\pagefile.sys',
        '\hiberfil.sys',
        '\swapfile.sys',
        '\DumpStack.log'
    ),
    [switch]$DryRun,
    [string]$OutJsonl = "",
    [ValidateRange(50, 5000)]
    [int]$BatchSize = 500,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    }
}

function Test-ExcludedPath {
    param([string]$Path)
    foreach ($pattern in $ExcludePathPatterns) {
        if ($Path -like ("*" + $pattern + "*")) {
            return $true
        }
    }
    return $false
}

function Find-MongoTool {
    param([string]$ToolName)
    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "C:\Program Files\MongoDB\Server\8.3\bin\$ToolName.exe",
        "C:\Program Files\MongoDB\Server\8.2\bin\$ToolName.exe",
        "C:\Program Files\MongoDB\Server\8.0\bin\$ToolName.exe",
        "C:\Program Files\MongoDB\Server\7.0\bin\$ToolName.exe",
        "C:\Program Files\MongoDB\Tools\100\bin\$ToolName.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function ConvertTo-ExtJsonDate([datetime]$dt) {
    return [ordered]@{ '$date' = $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
}

function New-FileMetaDocument {
    param([System.IO.FileInfo]$File, [datetime]$CollectedAtUtc, [string]$HostName)
    return [ordered]@{
        fullPath          = $File.FullName
        fileName          = $File.Name
        directory         = $File.DirectoryName
        extension         = $File.Extension
        length            = [int64]$File.Length
        creationTimeUtc   = (ConvertTo-ExtJsonDate $File.CreationTimeUtc)
        lastWriteTimeUtc  = (ConvertTo-ExtJsonDate $File.LastWriteTimeUtc)
        lastAccessTimeUtc = (ConvertTo-ExtJsonDate $File.LastAccessTimeUtc)
        attributes        = [string]$File.Attributes
        isReadOnly        = [bool]($File.Attributes -band [IO.FileAttributes]::ReadOnly)
        isHidden          = [bool]($File.Attributes -band [IO.FileAttributes]::Hidden)
        drive             = ([string]$File.Directory.Root.Name).TrimEnd('\')
        hostName          = $HostName
        collectedAtUtc    = (ConvertTo-ExtJsonDate $CollectedAtUtc)
        lookbackHours     = $LookbackHours
    }
}

function ConvertTo-JsonLine {
    param($Doc)
    # ConvertTo-Json escapes '$date' keys correctly for MongoDB Extended JSON.
    return ($Doc | ConvertTo-Json -Compress -Depth 8)
}

function Get-FilesRecursive {
    param([string]$Root)
    # Prefer EnumerationOptions when available (PowerShell 7+ / newer .NET).
    $enumType = [type]::GetType("System.IO.EnumerationOptions", $false)
    if ($enumType) {
        $opts = [System.IO.EnumerationOptions]::new()
        $opts.RecurseSubdirectories = $true
        $opts.IgnoreInaccessible = $true
        $opts.ReturnSpecialDirectories = $false
        return [System.IO.Directory]::EnumerateFiles($Root, "*", $opts)
    }

    # Windows PowerShell 5.1 fallback: directory walk with SearchOption / Get-ChildItem.
    $list = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if (Test-ExcludedPath -Path $dir) { continue }
        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if (-not (Test-ExcludedPath -Path $sub)) {
                    $stack.Push($sub)
                }
            }
        }
        catch { }

        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                $list.Add($file)
            }
        }
        catch { }
    }
    return $list
}

# --- init log ---
if (-not $LogPath) {
    $logDir = Join-Path $env:ProgramData "AnnoFileMetaCollector"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogPath = Join-Path $logDir ("collect-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
}
$script:LogPath = $LogPath
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

Write-Log "=== File meta collection started ==="
Write-Log "LookbackHours=$LookbackHours Database=$Database Collection=$Collection DryRun=$DryRun"

if (-not $Roots -or $Roots.Count -eq 0) {
    $Roots = @(
        Get-PSDrive -PSProvider FileSystem |
            Where-Object { $_.Used -ne $null -and $_.Root -match '^[A-Z]:\\$' } |
            ForEach-Object { $_.Root }
    )
    if (-not $Roots -or $Roots.Count -eq 0) {
        $Roots = @("C:\")
    }
}
Write-Log ("Roots: " + ($Roots -join ", "))

$cutoffLocal = (Get-Date).AddHours(-1 * $LookbackHours)
$cutoffUtc = $cutoffLocal.ToUniversalTime()
$collectedAtUtc = [datetime]::UtcNow
$hostName = $env:COMPUTERNAME
Write-Log "Cutoff(local)=$cutoffLocal Cutoff(utc)=$cutoffUtc Host=$hostName"

if (-not $OutJsonl) {
    $OutJsonl = Join-Path $env:TEMP ("file-meta-{0}.jsonl" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
}
if (Test-Path $OutJsonl) { Remove-Item $OutJsonl -Force }

$docs = New-Object System.Collections.Generic.List[object]
$skippedExcluded = 0
$skippedOld = 0
$errors = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Log "Root missing, skip: $root" "WARN"
        continue
    }
    Write-Log "Scanning $root ..."
    try {
        foreach ($path in (Get-FilesRecursive -Root $root)) {
            if (Test-ExcludedPath -Path $path) {
                $skippedExcluded++
                continue
            }
            try {
                $fi = New-Object System.IO.FileInfo $path
                if (-not $fi.Exists) { continue }
                if ($fi.LastWriteTimeUtc -lt $cutoffUtc) {
                    $skippedOld++
                    continue
                }
                [void]$docs.Add((New-FileMetaDocument -File $fi -CollectedAtUtc $collectedAtUtc -HostName $hostName))
            }
            catch {
                $errors++
                if ($errors -le 20) {
                    Write-Log "Skip file error: $path :: $($_.Exception.Message)" "WARN"
                }
            }
        }
    }
    catch {
        $errors++
        Write-Log "Root scan failed: $root :: $($_.Exception.Message)" "ERROR"
    }
}

Write-Log "Matched files (updated within ${LookbackHours}h): $($docs.Count)"
Write-Log "Skipped excluded≈$skippedExcluded skipped older≈$skippedOld errors=$errors"

$sw = New-Object System.IO.StreamWriter($OutJsonl, $false, $utf8NoBom)
try {
    foreach ($doc in $docs) {
        $sw.WriteLine((ConvertTo-JsonLine -Doc $doc))
    }
}
finally {
    $sw.Close()
}
Write-Log "JSONL written: $OutJsonl ($((Get-Item $OutJsonl).Length) bytes)"

if ($DryRun) {
    Write-Log "DryRun enabled — MongoDB write skipped."
    Write-Log "=== Done (dry-run) ==="
    exit 0
}

$mongosh = Find-MongoTool "mongosh"
$mongoimport = Find-MongoTool "mongoimport"
if (-not $mongosh -and -not $mongoimport) {
    Write-Log "FATAL: mongosh/mongoimport not found. Install MongoDB Shell or Database Tools." "ERROR"
    exit 1
}

function Invoke-EnsureIndexes {
    if (-not $mongosh) {
        Write-Log "mongosh not found; skip index creation (mongoimport-only mode)." "WARN"
        return
    }
    $js = @"
db = db.getSiblingDB('$Database');
db.$Collection.createIndex({ fullPath: 1 }, { unique: true, name: 'ux_fullPath' });
db.$Collection.createIndex({ lastWriteTimeUtc: -1 }, { name: 'ix_lastWriteTimeUtc' });
db.$Collection.createIndex({ collectedAtUtc: -1 }, { name: 'ix_collectedAtUtc' });
db.$Collection.createIndex({ hostName: 1, drive: 1 }, { name: 'ix_host_drive' });
print('indexes_ok');
"@
    $indexJs = Join-Path $env:TEMP "file-meta-indexes.js"
    [System.IO.File]::WriteAllText($indexJs, $js, $utf8NoBom)
    & $mongosh $MongoUri --quiet --file $indexJs 2>&1 | ForEach-Object { Write-Log "mongosh: $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to ensure indexes (mongosh exit $LASTEXITCODE)"
    }
}

function Invoke-UpsertViaMongoImport {
    if (-not $mongoimport) { return $false }
    if ($docs.Count -eq 0) { return $true }
    Write-Log "Upserting via mongoimport ($($docs.Count) docs)..."
    $output = & $mongoimport `
        --uri $MongoUri `
        --db $Database `
        --collection $Collection `
        --file $OutJsonl `
        --type json `
        --mode upsert `
        --upsertFields fullPath `
        2>&1
    $output | ForEach-Object { Write-Log "mongoimport: $_" }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-UpsertViaMongosh {
    if (-not $mongosh) {
        throw "mongosh was not found and mongoimport upsert failed/unavailable."
    }
    if ($docs.Count -eq 0) {
        Write-Log "No documents to upsert."
        return
    }

    Write-Log "Upserting via mongosh bulkWrite in batches of $BatchSize..."
    $total = $docs.Count
    for ($i = 0; $i -lt $total; $i += $BatchSize) {
        $count = [Math]::Min($BatchSize, $total - $i)
        $batch = $docs.GetRange($i, $count)
        $batchFile = Join-Path $env:TEMP ("file-meta-batch-{0}.json" -f $i)
        $batchJs = Join-Path $env:TEMP ("file-meta-batch-{0}.js" -f $i)

        $arrayJson = "[" + (($batch | ForEach-Object { ConvertTo-JsonLine -Doc $_ }) -join ",") + "]"
        [System.IO.File]::WriteAllText($batchFile, $arrayJson, $utf8NoBom)

        $batchFileJs = $batchFile.Replace("\", "\\")
        $js = @"
const fs = require('fs');
const raw = fs.readFileSync('$batchFileJs', 'utf8');
const docs = EJSON.parse(raw);
db = db.getSiblingDB('$Database');
const ops = docs.map(d => ({
  replaceOne: {
    filter: { fullPath: d.fullPath },
    replacement: d,
    upsert: true
  }
}));
const res = db.$Collection.bulkWrite(ops, { ordered: false });
print(JSON.stringify({
  matched: res.matchedCount,
  modified: res.modifiedCount,
  upserted: res.upsertedCount,
  batch: docs.length
}));
"@
        [System.IO.File]::WriteAllText($batchJs, $js, $utf8NoBom)
        $out = & $mongosh $MongoUri --quiet --file $batchJs 2>&1
        $out | ForEach-Object { Write-Log "mongosh batch ${i}: $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "mongosh bulkWrite failed at batch offset $i (exit $LASTEXITCODE)"
        }
    }
}

try {
    Invoke-EnsureIndexes

    $imported = $false
    if ($mongoimport -and $docs.Count -gt 0) {
        $imported = Invoke-UpsertViaMongoImport
        if (-not $imported) {
            Write-Log "mongoimport failed; falling back to mongosh." "WARN"
        }
    }
    if (-not $imported) {
        Invoke-UpsertViaMongosh
    }

    if ($mongosh) {
        $countJs = Join-Path $env:TEMP "file-meta-count.js"
        $iso = $collectedAtUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $cjs = @"
db = db.getSiblingDB('$Database');
const n = db.$Collection.countDocuments({});
const recent = db.$Collection.countDocuments({ collectedAtUtc: { `$gte: ISODate('$iso') } });
print(JSON.stringify({ total: n, thisRunCollectedAt: recent }));
"@
        [System.IO.File]::WriteAllText($countJs, $cjs, $utf8NoBom)
        & $mongosh $MongoUri --quiet --file $countJs 2>&1 | ForEach-Object { Write-Log "collection stats: $_" }
    }

    Write-Log "=== Done OK — upserted $($docs.Count) file meta document(s) into ${Database}.${Collection} ==="
    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log "=== Done FAILED ===" "ERROR"
    exit 1
}
