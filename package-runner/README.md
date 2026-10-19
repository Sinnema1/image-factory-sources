# Package Runner

[![Go Version](https://img.shields.io/badge/go-1.20+-007D9C?logo=go)](https://go.dev/)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows)](https://www.microsoft.com/windows/)

**Package Runner** is a production-quality CLI tool that executes approved software installation handlers during VM image builds.

## Table of Contents

- [Features](#-# Package Runner

[![Go Version](https://img.shields.io/badge/go-1.20+-007D9C?logo=go)](https://go.dev/)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows)](https://www.microsoft.com/windows/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Package Runner** is a production-quality Go CLI that executes approved software installation handlers during VM image builds. It provides deterministic, repeatable package installation with comprehensive validation, structured logging, and evidence collection.

## ✨ Features

### ✅ Core Capabilities
- **Deterministic Installation**: Exact name+version resolution with dependency ordering
- **Security-First**: No arbitrary code execution, strict validation, secrets redaction
- **Comprehensive Validation**: Artifacts (SHA-256, size), dependencies, schema
- **Structured Evidence**: JSON Lines logs + JSON evidence files
- **Multiple Handlers**: MSI, EXE, PowerShell, PSADT
- **Multiple Validators**: File, Registry, Service, Command

### ✅ Guardrails
- Uses `context.Context` and `os/exec` with separate executable/arguments
- No arbitrary handler paths (allow-list only)
- No inline shell commands
- Execute only from immutable lock files
- Never calls `os.Exit` outside CLI boundary
- Never auto-restarts machines
- Strict schema validation (rejects unknown fields)
- Path validation to prevent directory traversal

### ✅ Build Options
- Windows AMD64 executable (primary target)
- Windows ARM64 support (code ready)
- Linux AMD64 support (code ready)
- Pure Go (no CGO required)
- Version injection via linker flags
- Single static binary (no Go required on target VMs)

---

## 🏗️ Architecture

```
Image Recipe or Deployment Plan
    ↓
Resolver creates immutable lock
    ↓
Package Runner consumes lock
    ↓
Approved handlers install packages
    ↓
Validators confirm installed state
    ↓
Logs and evidence record results)
- [Architecture](#-architecture)
- [Installation](#-installation)
- [CLI Commands](#-cli-commands)
- [Examples](#-examples)
```

## Validator Interface

All validators implement the following interface:

```go
type Validator interface {
    Validate() (*models.ExecutionResult, error)
    ValidatorType() string
}
```

## Available Validators

There are four types of validators available:

1. [File Validator](#file-validator)
2. [Registry Validator](#registry-validator)
3. [Service Validator](#service-validator)
4. [Command Validator](#command-validator)

---

## File Validator

Validates file existence, version, hash, and size.

### Basic Usage in Package Definition

```yaml
validation:
  handler: file
  parameters:
    path: "C:\\Program Files\\MyApp\\app.exe"
    sha256: "a981351f704671fe6f3305a6dfe21a9693bd28cb50548306f419d337a7f5f32f"
    sizeBytes: 123456789
    version: "1.0.0"
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | Yes | The file path to validate |
| `sha256` | string | No | Expected SHA256 hash of the file |
| `sizeBytes` | integer | No | Expected file size in bytes |
| `version` | string | No | Expected file version |

### Behavior

- Checks if file exists at specified path
- Verifies file is not a directory
- Validates SHA256 hash if provided
- Validates file size if provided
- Validates version if provided (currently checks non-empty)

### Example Validation Result

```json
{
  "status": "success",
  "exitCode": 0,
  "stdout": "",
  "stderr": "",
  "duration": "1.234ms",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

If validation fails:

```json
{
  "status": "validation_failed",
  "error": "file hash mismatch: expected a981351..., got b234567...",
  "duration": "2.345ms",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

---

## Registry Validator

Validates Windows registry entries.

### Basic Usage in Package Definition

```yaml
validation:
  handler: registry
  parameters:
    hive: "HKEY_LOCAL_MACHINE"
    key: "SOFTWARE\\MyCompany\\MyApp"
    value: "Version"
    data: "1.0.0"
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `hive` | string | Yes | Registry hive (HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER, etc.) |
| `key` | string | Yes | Registry key path |
| `value` | string | Yes | Registry value name |
| `data` | string/number | Yes | Expected value data |

### Supported Hives

- `HKEY_LOCAL_MACHINE` (HKLM)
- `HKEY_CURRENT_USER` (HKCU)
- `HKEY_CLASSES_ROOT` (HKCR)
- `HKEY_USERS` (HKU)
- `HKEY_CURRENT_CONFIG` (HKCC)

### Behavior

- Opens the specified registry hive
- Opens the specified key
- Reads the specified value
- Compares with expected data

### Example Validation Result

```json
{
  "status": "success",
  "duration": "3.456ms",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

---

## Service Validator

Validates Windows service status.

### Basic Usage in Package Definition

```yaml
validation:
  handler: service
  parameters:
    serviceName: "MyService"
    state: "Running"
    startType: "Automatic"
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `serviceName` | string | Yes | Windows service name |
| `state` | string | Yes | Expected service state (Running, Stopped, etc.) |
| `startType` | string | No | Expected service start type (Automatic, Manual, Disabled) |

### Supported States

- `Running`
- `Stopped`
- `StartPending`
- `StopPending`
- `ContinuePending`
- `PausePending`
- `Paused`

### Supported Start Types

- `Automatic`
- `Manual`
- `Disabled`

### Behavior

- Opens service control manager
- Opens specified service
- Queries service status
- Compares with expected state and start type

### Example Validation Result

```json
{
  "status": "success",
  "duration": "4.567ms",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

---

## Command Validator

Validates by running an approved command or script.

### Basic Usage in Package Definition

```yaml
validation:
  handler: command
  parameters:
    command: "C:\\Validation\\check_install.exe"
    arguments: ["/verify", "/silent"]
    timeout: "2m"
```

### Parameters

| Parameter | Type | Required | Description | Default |
|-----------|------|----------|-------------|---------|
| `command` | string | Yes | Path to the command/executable to run |
| `arguments` | array of strings | No | Arguments to pass to the command | None |
| `timeout` | duration string | No | Timeout for command execution | 5m |

### Supported Argument Types

Arguments must be an array of strings:

```yaml
arguments:
  - "/verify"
  - "/silent"
  - "--version=1.0.0"
```

### Supported Timeout Formats

- `30s` - 30 seconds
- `2m` - 2 minutes
- `1h` - 1 hour
- `1m30s` - 1 minute 30 seconds

### Behavior

- Executes the specified command with arguments
- Captures stdout and stderr
- Validates exit code (must be 0 for success)
- Respects timeout
- Returns execution result

### Success Exit Codes

By default, only exit code `0` is considered success.

### Example Validation Result

For successful command:

```json
{
  "status": "success",
  "exitCode": 0,
  "stdout": "Service installed successfully\nVersion: 1.0.0",
  "stderr": "",
  "duration": "12.345ms",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

For failed command:

```json
{
  "status": "validation_failed",
  "exitCode": 1,
  "stdout": "",
  "stderr": "Error: Service not found",
  "duration": "5.678ms",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

For timeout:

```json
{
  "status": "timeout",
  "exitCode": -1,
  "stdout": "Partial output...",
  "stderr": "",
  "duration": "120.000ms",
  "timeout": true,
  "timestamp": "2024-01-01T00:00:00Z"
}
```

---

## Complete Validator Example

Here's a complete Package Definition with validation:

```yaml
apiVersion: packages.example/v1alpha1
kind: PackageDefinition
metadata:
  name: security-agent
  version: "8.4.1"
artifact:
  repository: software-packages
  path: security-agent/8.4.1
  filename: installer.exe
  sha256: "a981351f704671fe6f3305a6dfe21a9693bd28cb50548306f419d337a7f5f32f"
  sizeBytes: 123456789
install:
  handler: exe
  arguments: [/silent, /norestart]
  timeout: 20m
  successExitCodes: [0]
  restartExitCodes: [3010]
validation:
  handler: file
  parameters:
    path: "C:\\Program Files\\SecurityAgent\\agent.exe"
    sha256: "b23456789cdef0123456789abcdef01234567890"
    sizeBytes: 1024000
```

---

## Validator Selection Guide

| Use Case | Recommended Validator |
|----------|----------------------|
| Verify application files installed correctly | File Validator |
| Verify registry settings created | Registry Validator |
| Verify service installed and running | Service Validator |
| Run custom validation script | Command Validator |
| Verify file version | File Validator |
| Verify configuration files | File Validator |
| Verify software installed in Windows | Registry or Service Validator |

---

## Error Handling

All validators return a `models.ExecutionResult` with:

- `Status`: success, validation_failed, timeout, etc.
- `ExitCode`: Exit code from command (if applicable)
- `Stdout`: Standard output
- `Stderr`: Standard error
- `Duration`: Execution duration
- `Timestamp`: When validation occurred
- `Timeout`: Whether timeout occurred (boolean)

---

## Best Practices

1. **Use specific validators**: Prefer File, Registry, or Service validators over Command validator when possible.

2. **Validate critical files**: For software installations, validate:
   - Main executable
   - Configuration files
   - License files

3. **Combine validators**: A package can have multiple validation rules (though the current implementation processes one validation per package).

4. **Set appropriate timeouts**: Command validators should have reasonable timeouts.

5. **Use SHA256**: Always validate file hashes when possible for security.

6. **Validate service state**: For services, validate both state and start type.

7. **Test validation**: Test your validators independently to ensure they work as expected.
