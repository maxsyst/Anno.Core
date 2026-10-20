# MongoDB Windows Service Error 1053

Windows error **1053** (`The service did not respond to the start or control request in a timely fashion`) means `mongod.exe` exited before the SCM received `SERVICE_RUNNING`. The service line itself is usually fine:

```text
"C:\Program Files\MongoDB\Server\8.3\bin\mongod.exe" --config "C:\Program Files\MongoDB\Server\8.3\bin\mongod.cfg" --service
```

## Root causes (MongoDB 8.3)

1. Invalid `mongod.cfg` YAML (tabs, broken indentation, stray `mp:`, `security;` instead of `security:`)
2. Missing or non-writable `storage.dbPath` / `systemLog.path` (NETWORK SERVICE cannot write under Program Files)
3. Oversized `mongod.log`
4. Stale `mongod.lock` after unclean shutdown

## Fix (Administrator PowerShell)

```powershell
cd <repo>\scripts\windows
powershell -ExecutionPolicy Bypass -File .\Fix-MongoDB-Service-1053.ps1
```

Optional parameters:

```powershell
.\Fix-MongoDB-Service-1053.ps1 -MongoVersion 8.3 -DbPath C:\data\db -LogPath C:\data\log\mongod.log
```

The script will:

- Stop the MongoDB service
- Create `C:\data\db` and `C:\data\log`
- Grant write access to `NETWORK SERVICE`
- Backup and replace `mongod.cfg` with a valid config (see `mongod.cfg` in this folder)
- Diagnose by starting `mongod` in the foreground briefly
- Repair service `ImagePath` / account if needed
- Start the service and ping `27017`

## Manual config

If you only want the corrected config, copy `mongod.cfg` over:

`C:\Program Files\MongoDB\Server\8.3\bin\mongod.cfg`

Then:

```powershell
New-Item -ItemType Directory -Force C:\data\db, C:\data\log
icacls C:\data /grant "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)F" /T
Restart-Service MongoDB
```

## If it still fails

Run mongod in the console to see the real error:

```powershell
& "C:\Program Files\MongoDB\Server\8.3\bin\mongod.exe" --config "C:\Program Files\MongoDB\Server\8.3\bin\mongod.cfg"
```

Check the last lines of `C:\data\log\mongod.log`.
