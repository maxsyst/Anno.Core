# Windows MongoDB / File Meta Scripts

## 1. Fix MongoDB service Error 1053

See `Fix-MongoDB-Service-1053.ps1` and `mongod.cfg`.

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-MongoDB-Service-1053.ps1
```

## 2. Collect file metadata (last 24 hours) → MongoDB

`Collect-FileMeta-ToMongo.ps1` scans local drives for files whose `LastWriteTime` is within the last 24 hours, then **upserts** metadata into MongoDB:

| Field | Description |
|-------|-------------|
| `fullPath` | Unique key (upsert filter) |
| `fileName` / `directory` / `extension` | Path parts |
| `length` | File size (bytes) |
| `creationTimeUtc` / `lastWriteTimeUtc` / `lastAccessTimeUtc` | Timestamps |
| `attributes` / `isReadOnly` / `isHidden` | File flags |
| `drive` / `hostName` | Machine context |
| `collectedAtUtc` / `lookbackHours` | Collection run metadata |

**Database / collection (defaults):** `filemonitor.file_meta`

### Manual run

```powershell
# Full scan → MongoDB (requires mongosh or mongoimport + running mongod)
powershell -ExecutionPolicy Bypass -File .\Collect-FileMeta-ToMongo.ps1

# Preview only (writes JSONL, no DB write)
.\Collect-FileMeta-ToMongo.ps1 -Roots 'C:\Users' -DryRun

# Custom MongoDB target
.\Collect-FileMeta-ToMongo.ps1 `
  -MongoUri 'mongodb://127.0.0.1:27017' `
  -Database filemonitor `
  -Collection file_meta `
  -LookbackHours 24
```

Logs: `%ProgramData%\AnnoFileMetaCollector\collect-YYYYMMDD.log`

Query examples (mongosh):

```javascript
use filemonitor
db.file_meta.find().limit(5)
db.file_meta.countDocuments({})
db.file_meta.find({ extension: '.log' }).sort({ lastWriteTimeUtc: -1 })
```

## 3. Register Windows Scheduled Task (every 24 hours)

Run **once as Administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File .\Register-FileMetaCollector-Task.ps1
```

Options:

```powershell
# First fire at 03:00 local, then every 24 hours; limit roots
.\Register-FileMetaCollector-Task.ps1 -StartTime 03:00 -Roots 'C:\Users,D:\'

# Remove the task
.\Register-FileMetaCollector-Task.ps1 -Unregister
```

Task name: `Anno-FileMeta-Collector-24h` (runs as **SYSTEM**).

```powershell
Start-ScheduledTask -TaskName 'Anno-FileMeta-Collector-24h'
Get-ScheduledTaskInfo -TaskName 'Anno-FileMeta-Collector-24h'
```

## Prerequisites

1. MongoDB Windows service running (see section 1 if Error 1053)
2. `mongosh` and/or `mongoimport` on PATH or under `C:\Program Files\MongoDB\...`
3. Administrator rights to register the scheduled task
