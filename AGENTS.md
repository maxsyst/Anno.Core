# AGENTS.md

## Cursor Cloud specific instructions

### Overview

Anno.Core is a .NET 6.0 distributed microservices development framework (SDK). It is a library/NuGet-package codebase, not a standalone application. The solution file is `Anno.Core.sln` at the repo root.

### Prerequisites

- **.NET 6.0 SDK** must be installed. The update script installs it to `$HOME/.dotnet` via the official `dotnet-install.sh` script. Environment variables `DOTNET_ROOT` and `PATH` are set in `~/.bashrc`.

### Build

```
dotnet build Anno.Core.sln
```

Building via the solution file is required because `Directory.Build.props` references `$(SolutionDir)key.snk` for assembly signing. Running `dotnet build` or `dotnet test` on individual `.csproj` files will fail with `CS7027` (key.snk not found) unless you pass `/p:SolutionDir=/workspace/`.

### Tests

```
dotnet test Anno.Core.sln --filter "FullyQualifiedName~Anno.Test" --no-build
```

- The test project is `test/Anno.Test/` (NUnit 3, 23 tests).
- One test (`BuyProduct_test`) is an integration test that requires running AnnoCenter + AnnoService (Thrift). All other tests are self-contained.
- Always use `--no-build` after a full solution build to avoid the key.snk path issue.

### Running the Sample Services (E2E)

To test the framework end-to-end using the Thrift transport:

1. **Build the solution first:** `dotnet build Anno.Core.sln`
2. **Start AnnoCenter** (registration center, port 6660):
   ```
   cd samples/Thrift/AnnoCenter/bin/Debug/net6.0 && dotnet AnnoCenter.dll
   ```
3. **Start AnnoService** (microservice host, port 6659):
   ```
   cd samples/Thrift/AnnoService/bin/Debug/net6.0 && dotnet AnnoService.dll
   ```

AnnoService auto-registers with AnnoCenter at `127.0.0.1:6660`. The gRPC variants are under `samples/Grpc/` and work identically.

### Gotchas

- **Assembly signing:** Always build/test via `Anno.Core.sln` (not individual projects) to ensure `$(SolutionDir)` resolves the `key.snk` path correctly.
- **External services (MySQL, Redis, MongoDB, RabbitMQ):** All are optional and disabled by default in sample configs (`redisSwitch=false`, DB assemblies commented out). No external services are needed for the core framework or unit tests.
- **AnnoService multi-targets `net6.0;net461`:** On Linux, always use the `net6.0` target framework. The `net461` target is Windows-only.
