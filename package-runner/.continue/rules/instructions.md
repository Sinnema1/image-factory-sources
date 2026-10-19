# Instructions: Build the Package Installation Runner

## Role
Act as a senior Go engineer, Windows automation engineer, package engineering architect, and CI/CD engineer.

Build a production-quality Go CLI named `package-runner` with executable `package-runner.exe` that executes approved software installation handlers during VM image builds.


Do not stop at scaffolding. Produce compiling implementation code, schemas, tests, examples, build scripts, CI configutaion, and documentation. Do not claim that a test or build passed unless it was actually executed

## Objective

Build a production-quality Go CLI named `package-runner` with executable `package-runner.exe` that executes approved software installation handlers during VM image builds.

The CLI must remain independent of the image builder, CI platform, hypervisor, arifact repository and endpoing management platform.
The Pacage Runner is a reusable local package execution and validation engine. The VM factory is its first consumer, but in its design must also consider future desktop packaging, package qualification, repair, and post-rovisioning workflows

```text
Image Rescipe or Deployment Plan
  -> resolver creates an immutable lock
  -> Package Runner consumes the lock
  -> approved handlers install packages
  -> validators confirm installed state
  -> logs and evidence record the result

```

## Composition Rules

- Use separate package `name` and `version` fieds
- Every package selected in an Image Recipe is mandatory.
- Omit packages that do not belong in the image.
- Do not use `required` in the initial schema.
- Default `failurePolicy` is `fail`- `failurePolicy: continue` is an excpetional diagnostic policy only. A continued build is degraded and not publication-eligible by default


## Core Workflow

```text
Approved YAML manifest
  -> manifest validation
  -> artifact SHA-256 and size validation
  -> dependency/order resolution
  -> approved handler execution
  -> post-install validation
  -> structured logs and evidence
  -> deterministic success or failure exit code
```


## Initial Handlers

Implement:

- `msi`: runs `msiexec.exe` with argument arrays.
- `exe`: runs an exact governed executable with explicit silent arguments.
- `powershell`: runs an approved script non-interactively with no profile.
- `psadt`: invokes an explicitly configured PSADT entry point.

Handlers must not control package order, write secrets, restart the machine, or terminate the CLI process.

## Initial Validators

Implement:

- `file`: existence, version, optional hash, and size.
- `registry`: hive, key, value, and expected data on Windows.
- `service`: existence, state and optional start type on Windows.
- `command`: approved executable or validation script only. No inline shell commands.

## Required Behavior
- Strict schema validation for recipes, Package Difinitions, and locks
- Exact `name + version` resolution.
- Reject unkown fields, duplicates, mutable versions/paths, missing dependencies, and cycles.
- Validate artifact existence, SHA-256, and size before execution.
- Execute deterministically by dependecy and install order.
- Stop when any selectd package fails to resolve, install, or validate.
- Block dependents after dependency failure.
- Capture stdout, stderr, native exit code, timeout, duration, and restart state.
- Never restar automatically.
- Write JSON Lines logs and JSON evidence on success or failue.
- Record recipe, lock, Package Definition, and aritifact hashes.
- Redact secrets and sensitive aruguments


## Exceptional Continue Policy
 If implemented later, `failurePolicy: continue` must:
 - keep the package result as failed;
 - continue only independent packages;
 - mark dependents `blocked_dependency`
 - mark the overall result degraded
 - set `publicationEligible: false` by default; and retain complet evidence.

## Guardrails

- Use `context.Context` and `os/exe`
- Pass executables and arguments separately.
- No arbitrary handler paths or inline shell commands.
- No public downloads, mutable references, or automatic latest-version discovery in version1.
- No global Powershell execution-policy changes or crtificate validation bypass.
- Execute only from an immutable lock.
- Never call `os.Exit` outside the CLI boundary
- Structured Go types for logs, locks, and evidence
- Table-driven unit tests
- OS-specific files and build tags for Windows-only behavior

## Requirements
- Windows AMD64 executable is mandatory
- Windows ARM and Linux AMD64 builds are optional
- Target VM must not require Go to be installed
- Avoid CGO unless unavoidable and documented
- Build version information mus be injected through linker flags


## Required Tests

Test exact resolution, schema failures, duplicates, mutable valuess, hashes/sizes, dependencies/cycles, determistic locks, handler/validator allow lists, success, restart, failure, timeout, validation failue, stop-on-selected-package-failure, evidence, and redaction.

Do not stop at at scaffolding. Do not leave core TODOs. Do not clim tests passed unless executed

## CLI Commands

```powershell
package-runner.exe version

package-runner.exe handlers

package-runner.exe resolve `
  --recipe .\recipes\windows-vm.recipe.yaml `
  --package-root .\package-content `
  --output .\out\windows-vm.recipe.lock.yaml


package-runner.exe validate `
  --lock .\out\windows-vm.recipe.lock.yaml `
  --verify-artifacts

package-runner.exe install `
  --lock .\out\windows-vm.recipe.lock.yaml `
  --evidence-dir .\out\evidence `
  --execution-id 123456

package-runner.exe install-package `
  --lock .\out\windows-vm.recipe.lock.yaml `
  --package-id vmware-tools `
  --evidence-dir .\out\evidence

package-runner.exe detect --package-definition .\package.yml  
```

## Image Recipe Example

```yaml
apiVersion: image.example/v1alpha1
kind: ImageRecipe

metadata:
  name: windows-vm
  version: "0.0.1"
  baselineClassification: slim-vdi-base
target:
  platform: windows
  release: "11"
  architecture: amd64
  imageType: vm
defaults:
  failurePolicy: fail
packages:
  - name: vm-integration-tools
    version: "12.5.2"
    installOrder: 10
  - name: security-agent
    vertion: "8,4,1"
    installOrder: 20
    dependencies:
      - vm-integration-tools

```

## Package Definition Example

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
  restartExistCodes: [3010]
validation:
  handler: service
  parameters:
    serviceName: SecurityAgent
    state: Running
restartBehavior: report
```