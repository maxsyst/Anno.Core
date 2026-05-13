# Anno.Core Development Guide

## Cursor Cloud specific instructions

### Overview
Anno.Core is a .NET 6.0 distributed microservice framework. The solution (`Anno.Core.sln`) contains ~27 projects including core libraries, Thrift/gRPC transport layers, sample services, and tests.

### Build
Always build from the solution root to ensure `$(SolutionDir)` resolves correctly for assembly signing (`key.snk`):
```
dotnet build Anno.Core.sln
```
Do **not** build or run individual projects with `dotnet build <project>.csproj` or `dotnet run --project <project>` — this fails because `$(SolutionDir)` is unset and the `key.snk` path cannot be resolved. Instead, build from the solution and then run the built DLL directly.

### Tests
```
dotnet test Anno.Core.sln --verbosity normal
```
- 22/23 tests pass. The `BuyProduct_test` in `test/Anno.Test/ServiceCallService.cs` is an integration test that requires a running AnnoService instance and is expected to fail when run standalone.

### Running the application
The easiest way to run the framework locally is using the **Cocas** sample, which combines AnnoCenter (registration center) and AnnoService in a single process:
```bash
cd /workspace
dotnet build Anno.Core.sln
cd samples/Thrift/Cocas
dotnet bin/Debug/net6.0/Cocas.dll
```
This starts AnnoCenter on port **6660** and AnnoService on port **6659**. The service auto-registers with the center at `127.0.0.1:6660`.

Alternatively, run them separately (start AnnoCenter first):
```bash
cd samples/Thrift/AnnoCenter && dotnet bin/Debug/net6.0/AnnoCenter.dll
cd samples/Thrift/AnnoService && dotnet bin/Debug/net6.0/AnnoService.dll
```

### External dependencies
MySQL, Redis, MongoDB, and RabbitMQ are all **optional** and disabled by default in sample configs. No external services are needed for core development and testing.
