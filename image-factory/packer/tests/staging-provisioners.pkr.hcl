# Manual harness for the package staging provisioners.
#
# Runs the same staging steps as the `build` block in
# packer/templates/windows-11-vsphere.pkr.hcl against a retained, powered-on
# build VM over WinRM HTTPS, so file paths and environment variables can be
# debugged in minutes instead of a full build.
#
# Run from the manual `staging-harness` CI job, not from a workstation: the
# build VM only accepts WinRM from the runner.
#
# Keep the provisioners below in step with the template. They are duplicated
# rather than shared because HCL2 has no include mechanism for build or
# provisioner blocks; the only alternative is one template with two sources and
# a conditional, which is more risk than the duplication costs.
#
# TWO DELIBERATE DIFFERENCES. The install step sets the stand-in's
# force_exit_code knob, which the template never does. And the template ends
# with a guest cleanup step (Remove-BuildArtifact.ps1) that deletes the staging
# and evidence directories, the cached answer file and the uploaded scripts. This harness must NOT have it. The whole
# point of the harness is repeated runs against a retained VM, and cleaning up
# would destroy the thing under test — including the WinRM path the next run
# needs. Do not add it here to make the two files match.
#
#   scripts/runner/stage-packages.sh --emit-var-file build/package-vars.pkrvars.hcl
#   packer build \
#     -var-file=build/package-vars.pkrvars.hcl \
#     -var winrm_host=<vm address> -var winrm_username='<DOMAIN>\<account>' \
#     -var winrm_password=<from the environment> \
#     packer/tests/staging-provisioners.pkr.hcl
#
# Exit-code tests: -var force_exit_code=10, 11 or 12 makes the stand-in
# package-runner end with that code, and the run must fail AFTER
# install-result-harness.json has been downloaded. 3010 installs, then
# RESTARTS THE VM, runs the post-restart check and must pass. This works only
# with the stand-in (packer/fixtures/package-runner/), because the release
# cannot be made to fail on demand; the staging-harness job selects the
# stand-in itself when HARNESS_FORCE_EXIT_CODE is set.
#
# Seal test: -var seal_image=true runs the seal's Prepare stage and then starts
# its Final stage, as the template's shutdown command does. THE VM IS SEALED
# AND POWERS OFF: it cannot be used by this harness again. The job reads the
# result from vCenter (scripts/runner/verify-seal.sh). -var
# seal_force_failure=true makes the Final stage report a failure after doing
# its work; the VM must then stay powered on.
#
# Integrity test, for any package_runner: -var tamper_staged_file=true changes
# one staged package file after the upload. The install must end with 11,
# nothing may be installed, and the run must fail AFTER
# install-result-harness.json has been downloaded.

packer {
  # Matches the template. No required_plugins block: this harness uses the null
  # builder, and which plugin provides it depends on what the runner image
  # bundles. Add one only after confirming that against the image.
  required_version = ">= 1.16.0"
}

variable "winrm_host" {
  type = string
}

variable "winrm_username" {
  type = string
}

variable "winrm_password" {
  type      = string
  sensitive = true
}

# Deliberately short. The harness connects to a VM that is already running, so a
# host that does not answer is a failure to report in seconds, not a boot to
# wait out. The template's 45m default is for a machine that is still starting.
variable "winrm_timeout" {
  type        = string
  default     = "2m"
  description = "How long to wait for WinRM on the retained VM."
}

# Supplied by scripts/runner/stage-packages.sh --emit-var-file, exactly as for a
# real build. These, staging_dir and guest_evidence_dir must match the
# template: the harness replays its provisioners against a VM it built, so a
# different value would test a path the build never uses.
variable "package_lock" {
  type        = string
  description = "Runner path of the package-runner lock. Its sidecar, <lock>.sha256, is uploaded with it."
}

variable "package_artifact_root" {
  type        = string
  description = "Runner directory holding the verified package files as <name>/<version>/<file> (ADR 0003, C2)."
}

variable "package_runner" {
  type        = string
  description = "Runner path of the package-runner binary, or of the stand-in script until a release exists."
}

variable "execution_id" {
  type        = string
  description = "Identifier the guest tooling stamps into its evidence: the CI job id, or local-<timestamp>."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.execution_id))
    error_message = "The execution_id value may only contain letters, digits, '.', '_' and '-'."
  }
}

variable "staging_dir" {
  type        = string
  default     = "C:\\Packer\\staging"
  description = "Directory on the build VM that receives the lock, the package-runner binary and the package files. Removed by the guest cleanup."
}

variable "guest_evidence_dir" {
  type        = string
  default     = "C:\\Packer\\evidence"
  description = "Directory on the build VM where package-runner writes its evidence (ADR 0003, C4). Removed by the guest cleanup."
}

# Test knob, absent from the template. See the header.
variable "force_exit_code" {
  type        = string
  default     = ""
  description = "Makes the stand-in package-runner end `install` with this code: 10, 11, 12 or 3010."

  validation {
    condition     = contains(["", "10", "11", "12", "3010"], var.force_exit_code)
    error_message = "The force_exit_code value must be empty, 10, 11, 12 or 3010."
  }
}

# Test knob, absent from the template. See the header.
variable "tamper_staged_file" {
  type        = bool
  default     = false
  description = "Appends a line to one staged package file after the upload, so package-runner must refuse it with exit code 11."
}

# Test knobs, absent from the template in this form. See the header.
variable "seal_image" {
  type        = bool
  default     = false
  description = "Run the seal against the harness VM. The VM is sealed and powers off."
}

variable "seal_force_failure" {
  type        = bool
  default     = false
  description = "Makes the seal's Final stage report a failure, so the VM must stay powered on."
}

variable "seal_hold_seconds" {
  type    = number
  default = 120
}

variable "admin_group_sid" {
  type        = string
  default     = env("ADMIN_GROUP_SID")
  description = "SID of the group the bootstrap mapped into local Administrators. Needed only with seal_image."
}

variable "evidence_dir" {
  type    = string
  default = ""
}

variable "vm_name" {
  type    = string
  default = "harness-target"
}

# The locals below are the template's, unchanged.
# Guest paths for the install step. The lock and its sidecar keep their names;
# the binary keeps its extension, which decides how it is started below.
local "guest_lock" {
  expression = "${var.staging_dir}\\${basename(var.package_lock)}"
}

local "guest_artifact_root" {
  expression = "${var.staging_dir}\\packages"
}

local "guest_package_runner" {
  expression = "${var.staging_dir}\\${basename(var.package_runner)}"
}

# The agreed command line (ADR 0003, C3), minus the subcommand. A .ps1 is the
# stand-in in packer/fixtures/package-runner/, which only the forced-exit
# tests use now, and is started in its own
# powershell.exe, so it behaves like the executable it stands in for: its exit
# code arrives in $LASTEXITCODE and nothing it does can end the calling block.
#
# The executable writes its log to stderr. Windows PowerShell turns a native
# program's stderr into error records in a session with no console, and a
# session that stops on errors would end at the first log line, before the
# exit code is read. So for the executable the block continues on errors and
# stderr is merged into the output as plain text (package_runner_end). The
# steps after it decide pass or fail from the exit code, never from an error.
local "package_runner_start" {
  expression = can(regex("\\.ps1$", var.package_runner)) ? "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '${local.guest_package_runner}'" : "$ErrorActionPreference = 'Continue'; & '${local.guest_package_runner}'"
}

local "package_runner_end" {
  expression = can(regex("\\.ps1$", var.package_runner)) ? "" : " 2>&1 | ForEach-Object { \"$_\" }"
}

local "package_runner_args" {
  expression = "--lock '${local.guest_lock}' --artifact-root '${local.guest_artifact_root}' --evidence-dir '${var.guest_evidence_dir}' --execution-id '${var.execution_id}'"
}

# Where the install and post-restart check steps leave package-runner's exit
# code for the steps after them. Packer provisioners share no state, so the
# guest's disk is the only place a later step can read an earlier one's result.
local "install_exit_code_file" {
  expression = "${var.guest_evidence_dir}\\install-exit-code.txt"
}

local "verify_exit_code_file" {
  expression = "${var.guest_evidence_dir}\\verify-exit-code.txt"
}

local "evidence_directory" {
  expression = var.evidence_dir != "" ? var.evidence_dir : abspath("${path.root}/../../evidence")
}

# Keep these settings in step with the communicator block in
# packer/templates/windows-11-vsphere.pkr.hcl. They describe the listener that
# packer/unattended/enable-winrm.ps1 creates in the guest, so all three files
# have to agree on the port and the transport. The rationale for winrm_insecure
# is in the template; it is not repeated here.
source "null" "staging_test" {
  communicator = "winrm"

  winrm_host     = var.winrm_host
  winrm_port     = 5986
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password

  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_use_ntlm = true
  winrm_no_proxy = true
  winrm_timeout  = var.winrm_timeout
}

build {
  sources = ["source.null.staging_test"]

  # Guest communication proof, as in the template. The expected identity is the
  # account this harness connects as.
  provisioner "file" {
    source      = abspath("${path.root}/../provisioners/Test-GuestCommunicator.ps1")
    destination = "C:\\Windows\\Temp\\Test-GuestCommunicator.ps1"
  }

  # Kept in step with the template: inputs are set as direct assignments, not
  # environment_vars. See the template for why.
  provisioner "powershell" {
    inline = [
      "$env:EXPECTED_IDENTITY = '${var.winrm_username}'",
      "$env:RESULT_PATH = 'C:\\Windows\\Temp\\communicator-result.json'",
      "$env:COMMUNICATOR = 'winrm'",
      "$env:TRANSPORT = 'https'",
      "$env:AUTHENTICATION = 'ntlm'",
      "$env:VM_NAME = '${var.vm_name}'",
      "& 'C:\\Windows\\Temp\\Test-GuestCommunicator.ps1'",
      "exit $LASTEXITCODE"
    ]
  }

  # Downloaded under a distinct name. The template writes plain
  # communicator-result.json to the same evidence/ directory, so sharing the name
  # would let a harness run silently overwrite a real build's evidence.
  # The suffix keeps it matching collect-evidence.sh's `communicator-result*.json`
  # glob, so it is still classified rather than falling through to "other".
  provisioner "file" {
    direction   = "download"
    source      = "C:\\Windows\\Temp\\communicator-result.json"
    destination = "${local.evidence_directory}/communicator-result-harness.json"
  }

  # The install sequence below is the template's, provisioner for provisioner,
  # and must stay in step with it; the reasons for each step and for their
  # order are in the template's comments and are not repeated here. The two
  # differences: the first line of the install step sets the stand-in's test
  # knob, and the downloads carry the -harness suffix, for the same reason as
  # the communicator result above.
  provisioner "powershell" {
    inline = [
      "foreach ($dir in @('${var.staging_dir}', '${var.guest_evidence_dir}')) { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }; New-Item -ItemType Directory -Path $dir -Force | Out-Null }",
      "New-Item -ItemType Directory -Path '${local.guest_artifact_root}' -Force | Out-Null",
      "if (-not (Test-Path -LiteralPath '${local.guest_artifact_root}' -PathType Container)) { throw 'The staging directory was not created.' }",
      "Write-Host 'Staging directory ready: ${var.staging_dir}'"
    ]
  }

  provisioner "file" {
    source      = var.package_lock
    destination = local.guest_lock
  }

  provisioner "file" {
    source      = "${var.package_lock}.sha256"
    destination = "${local.guest_lock}.sha256"
  }

  provisioner "file" {
    source      = var.package_runner
    destination = local.guest_package_runner
  }

  provisioner "file" {
    source      = "${var.package_artifact_root}/"
    destination = local.guest_artifact_root
  }

  # Test knob only (see the header). The file changes after the runner-side
  # check and the upload, which is exactly the case the guest-side hash
  # re-check exists for.
  provisioner "powershell" {
    inline = [
      "if ('${var.tamper_staged_file}' -ne 'true') { Write-Host 'Staged files left as uploaded.'; exit 0 }",
      "$target = Get-ChildItem -LiteralPath '${local.guest_artifact_root}' -Recurse -File | Sort-Object FullName | Select-Object -First 1",
      "if ($null -eq $target) { Write-Host 'No staged file to tamper with.'; exit 1 }",
      "Add-Content -LiteralPath $target.FullName -Value '# changed by the harness after upload' -Encoding ASCII",
      "Write-Host \"Tampered with $($target.FullName): the install must now end with exit code 11.\""
    ]
  }

  provisioner "powershell" {
    inline = [
      "$env:PACKAGE_RUNNER_STANDIN_FORCE_EXIT_CODE = '${var.force_exit_code}'",
      "${local.package_runner_start} install ${local.package_runner_args}${local.package_runner_end}",
      "$code = $LASTEXITCODE",
      "Set-Content -LiteralPath '${local.install_exit_code_file}' -Value $code -Encoding ASCII",
      "Write-Host \"package-runner install exit code: $code\"",
      "if (-not (Test-Path -LiteralPath '${var.guest_evidence_dir}\\install-result.json' -PathType Leaf)) { Write-Host 'package-runner wrote no install-result.json.'; exit 1 }",
      "exit $code"
    ]
    valid_exit_codes = [0, 10, 11, 12, 3010]
  }

  provisioner "file" {
    direction   = "download"
    source      = "${var.guest_evidence_dir}\\install-result.json"
    destination = "${local.evidence_directory}/install-result-harness.json"
  }

  provisioner "powershell" {
    inline = [
      "$code = Get-Content -LiteralPath '${local.install_exit_code_file}' -TotalCount 1",
      "if ($code -ne '0' -and $code -ne '3010') { Write-Host \"Software install failed: package-runner exit code $code (10 package failed, 11 integrity or lock, 12 not elevated). See install-result.json.\"; exit 1 }",
      "Write-Host \"Software install accepted: package-runner exit code $code.\""
    ]
  }

  provisioner "windows-restart" {
    restart_command = "powershell.exe -NoProfile -NonInteractive -Command \"if ((Get-Content -LiteralPath '${local.install_exit_code_file}' -TotalCount 1) -eq '3010') { shutdown.exe /r /f /t 5 /c 'packer restart' }\""
    restart_timeout = "15m"
  }

  provisioner "powershell" {
    inline = [
      "${local.package_runner_start} verify ${local.package_runner_args}${local.package_runner_end}",
      "$code = $LASTEXITCODE",
      "Set-Content -LiteralPath '${local.verify_exit_code_file}' -Value $code -Encoding ASCII",
      "Write-Host \"package-runner verify exit code: $code\"",
      "if (-not (Test-Path -LiteralPath '${var.guest_evidence_dir}\\install-result-verify.json' -PathType Leaf)) { Write-Host 'package-runner wrote no install-result-verify.json.'; exit 1 }",
      "exit $code"
    ]
    valid_exit_codes = [0, 10, 11, 12]
  }

  provisioner "file" {
    direction   = "download"
    source      = "${var.guest_evidence_dir}\\install-result-verify.json"
    destination = "${local.evidence_directory}/install-result-verify-harness.json"
  }

  provisioner "powershell" {
    inline = [
      "$code = Get-Content -LiteralPath '${local.verify_exit_code_file}' -TotalCount 1",
      "if ($code -ne '0') { Write-Host \"Installed-state check failed: package-runner exit code $code. See install-result-verify.json.\"; exit 1 }",
      "Write-Host 'Installed-state check passed.'"
    ]
  }

  # The seal's first stage, as in the template. The harness VM came from a
  # finished build, so the cleanup step that normally runs before it has
  # already removed the build-time local accounts.
  provisioner "powershell" {
    script = abspath("${path.root}/../provisioners/Invoke-ImageSeal.ps1")
    environment_vars = [
      "SEAL_IMAGE=${var.seal_image}",
      "ADMIN_GROUP_SID=${var.admin_group_sid}",
      "EXECUTION_ID=${var.execution_id}",
      "SETUP_ACCOUNT=pkr-setup",
      "SEAL_HOLD_SECONDS=${var.seal_hold_seconds}",
      "SEAL_FORCE_FAILURE=${var.seal_force_failure ? "1" : "0"}",
      "RESULT_PATH=C:\\Windows\\Temp\\seal-prepare-result.json"
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "C:\\Windows\\Temp\\seal-prepare-result.json"
    destination = "${local.evidence_directory}/seal-prepare-result-harness.json"
  }

  # The template starts the Final stage from its shutdown command. The null
  # builder has none, so the harness starts it here, as its last act.
  provisioner "powershell" {
    inline = [
      "if ('${var.seal_image}' -ne 'true') { Write-Host 'Seal not requested: the VM is left as it is.'; exit 0 }",
      "schtasks.exe /run /tn 'Packer image seal'",
      "if ($LASTEXITCODE -ne 0) { Write-Host 'The seal task could not be started.'; exit 1 }",
      "Write-Host 'Seal task started. This VM is being sealed and will power off; its result is read from vCenter.'"
    ]
  }
}
