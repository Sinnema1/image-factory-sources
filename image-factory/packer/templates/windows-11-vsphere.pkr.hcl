packer {
  required_version = ">= 1.16.0"
  required_plugins {
    vsphere = {
      source  = "github.com/vmware/vsphere"
      version = "2.4.0"
    }
  }
}

# Variables for VM configuration. The ISO paths are not variables: they come from
# the qualification records (see local "iso_paths" below).
variable "vm_name" {
  type = string
}

variable "vm_folder" {
  type = string
}

variable "datacenter" {
  type = string
}

variable "cluster" {
  type = string
}

variable "datastore" {
  type = string
}

variable "network" {
  type = string
}

# Variables for vCenter connection
variable "vcenter_host" {
  type    = string
  default = env("VCENTER_HOST")
}

variable "vcenter_insecure_connection" {
  type    = bool
  default = false
}

variable "vcenter_username" {
  type    = string
  default = env("VCENTER_USERNAME")
}

variable "vcenter_password" {
  type      = string
  default   = env("VCENTER_PASSWORD")
  sensitive = true
}

variable "admin_service_account" {
  type    = string
  default = env("ADMIN_SERVICE_ACCOUNT")
}

variable "admin_service_account_password" {
  type      = string
  sensitive = true
  default   = env("ADMIN_SERVICE_ACCOUNT_PASSWORD")
}

variable "ad_domain" {
  type    = string
  default = env("AD_DOMAIN")
}

variable "ad_netbios_domain" {
  type    = string
  default = env("AD_NETBIOS_DOMAIN")
}

variable "windows_computer_name" {
  type = string
}

variable "packer_runner_source_ip" {
  type        = string
  default     = env("PACKER_RUNNER_SOURCE_IP")
  description = "Source IPv4 address permitted to reach WinRM on the temporary Windows VM."

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.packer_runner_source_ip))
    error_message = "The Packer runner source IP must be an IPv4 address. Set PACKER_RUNNER_SOURCE_IP or the packer_runner_source_ip variable."
  }
}

variable "winrm_timeout" {
  type        = string
  default     = "45m"
  description = "How long Packer waits for the WinRM communicator after the guest reports an IP address."
}

# The domain group granted local administrator rights in the guest. Supplied as
# variables rather than baked into enable-winrm.ps1 so the group is not a
# property of the tracked script. The SID is what the bootstrap acts on; the
# name is for the build log only. See configs/*.example for the lab's values.
#
# This mapping survives into every clone, so it is a pre-seal cleanup item
# (ADR 0002 and the artifact list at the top of enable-winrm.ps1).
variable "admin_group_sid" {
  type        = string
  default     = env("ADMIN_GROUP_SID")
  description = "SID of the domain group to map into the guest's local Administrators."

  validation {
    condition     = can(regex("^S-1-5-21-([0-9]+-){3}[0-9]+$", var.admin_group_sid))
    error_message = "The admin group SID must be a domain SID such as S-1-5-21-x-y-z-rid. Set ADMIN_GROUP_SID or the admin_group_sid variable."
  }
}

variable "admin_group_name" {
  type        = string
  default     = env("ADMIN_GROUP_NAME")
  description = "DOMAIN\\GROUP display name for that SID. Used only in the guest's build log."

  validation {
    condition     = length(var.admin_group_name) > 0
    error_message = "The admin group name must not be empty. Set ADMIN_GROUP_NAME or the admin_group_name variable."
  }
}

# First-run setup (OOBE) inputs. The answer file finishes OOBE with one local
# administrator, because a client edition will not finish without an account,
# and a master left mid-OOBE would put every desktop made from it there too
# (ADR 0002). The guest cleanup deletes the account before the build ends.
variable "setup_account_name" {
  type        = string
  default     = "pkr-setup"
  description = "Local administrator the answer file creates to finish Windows first-run setup. Deleted by the guest cleanup."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{0,19}$", var.setup_account_name))
    error_message = "The setup account name must start with a letter and be at most 20 letters, digits or hyphens."
  }
}

variable "windows_time_zone" {
  type        = string
  default     = "UTC"
  description = "Windows time zone ID set in the image (for example UTC or Eastern Standard Time). Checked by the guest cleanup."

  validation {
    condition     = can(regex("^[A-Za-z0-9 .()+-]+$", var.windows_time_zone))
    error_message = "The Windows time zone must be a Windows time zone ID such as UTC, not an IANA name."
  }
}

# Software install inputs (ADR 0003). scripts/runner/stage-packages.sh checks
# the lock and the package-runner binary against their committed SHA-256 values,
# verifies the package files, and writes these values (--emit-var-file). They
# have no defaults on purpose: a build whose inputs were not verified on the
# runner must not start.
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

variable "seal_image" {
  type        = bool
  default     = false
  description = "Seal the image as the build's last act (ADR 0002): remove the WinRM listeners, the build certificate, the firewall rule, the administrative group mapping and the build identity's profile, then shut down. A sealed VM cannot be reached by the build or the harness again. Off until sealing is proved and publishing exists."
}

variable "seal_hold_seconds" {
  type        = number
  default     = 120
  description = "How long the sealed guest stays on after reporting its result, so the runner can read it from vCenter before it is gone (scripts/runner/verify-seal.sh)."

  validation {
    condition     = var.seal_hold_seconds >= 30 && var.seal_hold_seconds <= 600
    error_message = "The seal_hold_seconds value must be between 30 and 600."
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

variable "evidence_dir" {
  type        = string
  default     = ""
  description = "Runner directory for downloaded evidence. Defaults to evidence/ in the repository."
}

# Which qualification records the build reads its ISO paths from (see the ISO
# locals below). Each environment has its own records, measured from its own
# datastore copies, so the record is chosen per environment rather than named
# in the template: when this was a literal path, a build in any environment
# other than the lab would have silently attached the lab's ISOs. The defaults are
# The lab's, so the lab builds are unchanged.
#
# File names only, resolved under packer/sources/windows/. The pattern rejects
# a path, so a value cannot point the build at a record outside that folder.
variable "windows_iso_record" {
  type        = string
  default     = "windows-11.json"
  description = "Qualification record for the Windows ISO, a file name in packer/sources/windows/."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+\\.json$", var.windows_iso_record))
    error_message = "The windows_iso_record value must be a .json file name in packer/sources/windows/, not a path."
  }
}

variable "vmware_tools_iso_record" {
  type        = string
  default     = "vmware-tools.json"
  description = "Qualification record for the VMware Tools ISO, a file name in packer/sources/windows/."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+\\.json$", var.vmware_tools_iso_record))
    error_message = "The vmware_tools_iso_record value must be a .json file name in packer/sources/windows/, not a path."
  }
}

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
# stand-in in packer/fixtures/package-runner/ and is started in its own
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

# The ISOs the build boots, read from their qualification records (ADR 0004).
# The record is what verify-iso.sh and verify-datastore-iso.sh check, so taking
# the path from it means the build attaches the exact item that was qualified.
# The path used to live in the untracked variable file as well, and nothing
# checked that the two copies agreed.
#
# A record missing datastore or datastorePath fails packer validate, so an
# incomplete record cannot produce a build. The records keep the two fields
# apart so nothing has to parse brackets; Packer's "[datastore] path" form is
# composed here.
local "windows_iso" {
  expression = jsondecode(file(abspath("${path.root}/../sources/windows/${var.windows_iso_record}")))
}

local "vmware_tools_iso" {
  expression = jsondecode(file(abspath("${path.root}/../sources/windows/${var.vmware_tools_iso_record}")))
}

local "iso_paths" {
  expression = [
    "[${local.windows_iso.datastore}] ${local.windows_iso.datastorePath}",
    "[${local.vmware_tools_iso.datastore}] ${local.vmware_tools_iso.datastorePath}",
  ]
}

# Marked sensitive so Packer masks the XML-escaped form of the password in
# logs. Masking matches the exact string, and escaping changes it whenever the
# password contains & < > " or '.
local "admin_service_account_password_xml" {
  expression = replace(
    replace(
      replace(
        replace(
          replace(
            var.admin_service_account_password,
            "&",
            "&amp;"
          ),
          "<",
          "&lt;"
        ),
        ">",
        "&gt;"
      ),
      "\"",
      "&quot;"
    ),
    "'",
    "&apos;"
  )
  sensitive = true
}

# The setup account's password, generated for each build and never used to sign
# in. The fixed prefix adds an uppercase letter to the UUID's lowercase letters,
# digits and hyphens, so the value meets a complexity policy that wants three or
# four character classes, and none of its characters needs XML escaping.
local "setup_account_password" {
  expression = "Pkr-${uuidv4()}"
  sensitive  = true
}

# Packer vSphere ISO Builder
source "vsphere-iso" "windows-11" {
  # vCenter connection
  vcenter_server      = var.vcenter_host
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection
  datacenter          = var.datacenter

  # VM placement
  cluster   = var.cluster
  datastore = var.datastore
  network_adapters {
    network      = var.network
    network_card = "vmxnet3"
  }
  folder  = var.vm_folder
  vm_name = var.vm_name

  # Two ISOs are attached, in this order: Windows, then VMware Tools. The guest
  # bootstrap has to tell them apart at runtime, which is why
  # packer/unattended/enable-winrm.ps1 identifies the Tools drive by content
  # rather than by drive letter.
  iso_paths = local.iso_paths

  # VM hardware.
  #
  # The first three are Windows 11 install prerequisites, not preferences:
  # Setup refuses to install without TPM 2.0 and Secure Boot. `efi-secure` also
  # determines how the machine boots the install media, which is what makes the
  # boot_command sequence below behave as it does. Changing any of them means
  # re-deriving that sequence.
  guest_os_type        = "windows11_64Guest"
  firmware             = "efi-secure"
  vTPM                 = true
  disk_controller_type = ["pvscsi"]

  # Build-time sizing only. This is what the temporary build VM gets so Setup
  # runs at a reasonable speed; it is not the spec of the desktops cloned from
  # the image, which the Phase 2 deployment decides (ADR 0002).
  CPUs = 2
  RAM  = 4096

  storage {
    # Megabytes, so this is ~58.6 GiB rather than 60 GB. The answer file's third
    # partition is Extend=true, so it grows to fill whatever is set here: this
    # value alone determines the guest's C: size.
    disk_size             = 60000
    disk_thin_provisioned = true
  }


  # The build floppy. Windows Setup auto-detects an answer file named
  # autounattend.xml at the root of removable media, which is why the rendered
  # file below must keep that exact name and stay at the root.
  #
  # The floppy becomes A: in the guest, and the answer file invokes the
  # bootstrap as A:\enable-winrm.ps1. Both files must be here for that to work.
  #
  # Two mechanisms because they do different things: floppy_files copies a file
  # as-is, floppy_content writes generated content. enable-winrm.ps1 is static;
  # autounattend.xml is rendered per build.
  floppy_files = [
    abspath("${path.root}/../unattended/enable-winrm.ps1")
  ]

  floppy_content = {
    "autounattend.xml" = templatefile(
      abspath("${path.root}/../unattended/autounattend.xml.pkrtpl"),
      {
        windows_computer_name              = var.windows_computer_name
        ad_domain                          = var.ad_domain
        admin_service_account              = var.admin_service_account
        admin_service_account_password_xml = local.admin_service_account_password_xml
        packer_runner_source_ip            = var.packer_runner_source_ip
        admin_group_sid                    = var.admin_group_sid
        admin_group_name                   = var.admin_group_name
        setup_account_name                 = var.setup_account_name
        setup_account_password             = local.setup_account_password
        windows_time_zone                  = var.windows_time_zone
      }
    )
  }

  # WinRM communicator for post-install guest control.
  # HTTPS on 5986: Packer's NTLM client authenticates but does not encrypt
  # WinRM messages, and the guest keeps AllowUnencrypted = false, so plain HTTP
  # on 5985 is rejected. The guest presents a per-build self-signed certificate
  # (enable-winrm.ps1), hence winrm_insecure.
  communicator = "winrm"

  winrm_username = "${var.ad_netbios_domain}\\${var.admin_service_account}"
  winrm_password = var.admin_service_account_password

  winrm_port     = 5986
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_use_ntlm = true
  winrm_no_proxy = true
  winrm_timeout  = var.winrm_timeout

  # A sealed build does not shut down directly. It starts the task the seal's
  # Prepare stage registered, which removes the WinRM channel this command
  # arrived on, checks its own work, and shuts the machine down only if the
  # image is sealed. If it is not, the machine stays on and Packer fails here
  # on shutdown_timeout, which is the intended outcome.
  shutdown_command = var.seal_image ? "schtasks.exe /run /tn \"Packer image seal\"" : "shutdown.exe /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout = "15m"

  # destroy = false retains the VM only after a successful build. A failed or
  # halted build is cleaned up by the builder unless Packer runs with
  # -on-error=abort (see scripts/runner/build-diagnostic.sh).
  destroy             = false
  convert_to_template = false
  create_snapshot     = false

  # Keystrokes sent to the VM console to get Windows Setup started. This is the
  # most fragile block in the template: it is timing-dependent and specific to
  # this ISO's boot behavior, so it is not portable to a different Windows
  # build or a different firmware setting.
  #
  # Treat it as a unit. Changing one step usually means re-deriving the rest by
  # watching a build on the vSphere console.
  #
  #   <tab>, <esc>       dismiss the "Press any key to boot from CD" prompt
  #                      without actually booting from it twice
  #   d, w               navigate Setup's initial prompts
  #   <f8>, cmd          open a command prompt inside WinPE, which is the only
  #                      way to run the two commands below
  #   wpeutil updatebootfile
  #                      a workaround, not a normal Setup step: without it the
  #                      boot configuration is not refreshed and Setup can fail
  #                      to find the answer file on the floppy
  #   wpeinit            initialises WinPE networking and device support so the
  #                      floppy is present before Setup reads autounattend.xml
  #   exit               hands control back to Setup, which then runs unattended
  #
  # The <wait> markers are deliberate. Removing them makes the build fail
  # intermittently rather than reliably, which is much harder to diagnose.
  boot_command = [
    "<tab><wait>",
    "<esc><wait>",
    "<wait5>",
    "d<wait>",
    "w<wait>",
    "<enter><wait>",
    "<f8><wait>",
    "cmd<enter><wait>",
    "wpeutil updatebootfile<enter><wait>",
    "wpeinit<enter><wait>",
    "exit<enter>"
  ]
}

build {
  sources = ["source.vsphere-iso.windows-11"]

  # Guest communication proof. Runs first, so nothing else starts unless Packer
  # is connected as the expected administrative service account. The result
  # holds booleans, the computer name and the values below, never an account
  # name or credential. Keep COMMUNICATOR, TRANSPORT and AUTHENTICATION in step
  # with the communicator settings in the source block.
  provisioner "file" {
    source      = abspath("${path.root}/../provisioners/Test-GuestCommunicator.ps1")
    destination = "C:\\Windows\\Temp\\Test-GuestCommunicator.ps1"
  }

  # The inputs are set as direct assignments rather than Packer's
  # environment_vars, which did not reach the script as the first command
  # after a fresh reboot (observed: the check ran, but EXPECTED_IDENTITY was
  # empty inside it). This matches how winrm_username above and staging_dir
  # below are already passed into inline commands.
  provisioner "powershell" {
    inline = [
      "$env:EXPECTED_IDENTITY = '${var.ad_netbios_domain}\\${var.admin_service_account}'",
      "$env:RESULT_PATH = 'C:\\Windows\\Temp\\communicator-result.json'",
      "$env:COMMUNICATOR = 'winrm'",
      "$env:TRANSPORT = 'https'",
      "$env:AUTHENTICATION = 'ntlm'",
      "$env:VM_NAME = '${var.vm_name}'",
      "& 'C:\\Windows\\Temp\\Test-GuestCommunicator.ps1'",
      # Load-bearing. A `powershell` inline block reports the exit status of the
      # block, not of a script called inside it, so without this line the guest
      # check can exit 1 and the build carries on regardless.
      "exit $LASTEXITCODE"
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "C:\\Windows\\Temp\\communicator-result.json"
    destination = "${local.evidence_directory}/communicator-result.json"
  }

  # Software install (ADR 0003, steps 3 and 4): transfer the lock, the
  # package-runner binary and the verified package files, run the install,
  # collect its evidence, and only then decide whether the build goes on.
  # stage-packages.sh verified all three inputs on the runner before Packer
  # started. This repository never parses the lock; package-runner does.
  #
  # The provisioners from here to the guest cleanup are order-coupled and must
  # stay in this order. packer/tests/staging-provisioners.pkr.hcl repeats the
  # sequence; keep the two in step.
  #
  # This one has to come first because Packer's `file` provisioner will not
  # create a missing destination directory. Both directories are emptied, not
  # just created: a retained VM that is provisioned again must not keep files
  # from the run before, least of all an old install-result.json that the
  # download below would collect as this run's evidence.
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

  # The sidecar lets package-runner detect a lock corrupted in transfer. It is
  # the same committed file the runner checked the lock against.
  provisioner "file" {
    source      = "${var.package_lock}.sha256"
    destination = "${local.guest_lock}.sha256"
  }

  provisioner "file" {
    source      = var.package_runner
    destination = local.guest_package_runner
  }

  # The trailing slash is load-bearing: with it the directory's contents land
  # in the destination, giving <artifact root>\<name>\<version>\<file> (C2);
  # without it Packer nests a second "packages" folder inside the first.
  provisioner "file" {
    source      = "${var.package_artifact_root}/"
    destination = local.guest_artifact_root
  }

  # Install. Every exit code the contract defines is accepted here, so that
  # the evidence is downloaded before the build fails on one of them; the step
  # after the download is what fails the build. Anything else (a crash, a
  # missing binary) fails immediately.
  #
  # Packer's WinRM download does not fail on a missing file, so the result
  # file's existence is checked here, where a missing file can still stop the
  # build: C4 requires a result on every run, pass or fail.
  provisioner "powershell" {
    inline = [
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
    destination = "${local.evidence_directory}/install-result.json"
  }

  # 0 is installed; 3010 is installed with a restart owed, which the next two
  # steps settle. 10, 11 and 12 fail the build here, with their evidence
  # already on the runner.
  provisioner "powershell" {
    inline = [
      "$code = Get-Content -LiteralPath '${local.install_exit_code_file}' -TotalCount 1",
      "if ($code -ne '0' -and $code -ne '3010') { Write-Host \"Software install failed: package-runner exit code $code (10 package failed, 11 integrity or lock, 12 not elevated). See install-result.json.\"; exit 1 }",
      "Write-Host \"Software install accepted: package-runner exit code $code.\""
    ]
  }

  # package-runner never reboots; the build owns the restart (C3). Packer
  # cannot skip a provisioner at runtime, so the condition is inside the
  # restart command: it schedules a restart only when the install asked for
  # one. When it does nothing, the provisioner finds no restart pending and
  # returns as soon as the guest answers.
  provisioner "windows-restart" {
    restart_command = "powershell.exe -NoProfile -NonInteractive -Command \"if ((Get-Content -LiteralPath '${local.install_exit_code_file}' -TotalCount 1) -eq '3010') { shutdown.exe /r /f /t 5 /c 'packer restart' }\""
    restart_timeout = "15m"
  }

  # Post-restart check: a read-only run of each package's validation against
  # the same lock, which gives a package that asked for a restart its final
  # status ("restart_required" is never one). It runs on every build, restart
  # or not, so there is one sequence and its evidence always exists.
  #
  # This can be the first command after a reboot, which is exactly where
  # environment_vars failed to arrive (ADR 0001 addendum): its inputs are
  # literal arguments, and the block ends by returning the tool's own code.
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
    destination = "${local.evidence_directory}/install-result-verify.json"
  }

  provisioner "powershell" {
    inline = [
      "$code = Get-Content -LiteralPath '${local.verify_exit_code_file}' -TotalCount 1",
      "if ($code -ne '0') { Write-Host \"Installed-state check failed: package-runner exit code $code. See install-result-verify.json.\"; exit 1 }",
      "Write-Host 'Installed-state check passed.'"
    ]
  }

  # Guest cleanup. Everything below must stay last: it removes the staging
  # and evidence directories and the files the downloads above read, so moving
  # it earlier breaks those downloads.
  #
  # The bootstrap transcript is collected before it is deleted. It is the only
  # record of what enable-winrm.ps1 did during specialize, including the
  # administrative group mapping, none of which reaches the Packer console.
  provisioner "file" {
    direction   = "download"
    source      = "C:\\Windows\\Temp\\enable-winrm-bootstrap.log"
    destination = "${local.evidence_directory}/enable-winrm-bootstrap.log"
  }

  # Removes the answer file Windows Setup cached in C:\Windows\Panther, which
  # holds the domain-join password in plaintext in its unscrubbed copy, plus the
  # cheap build leftovers. Fails the build if any credential material survives.
  #
  # This is NOT the pre-seal cleanup: the WinRM listener, build certificate,
  # firewall rule and admin group mapping are left in place, because ADR 0002
  # requires listener removal to happen inside the shutdown step and that work
  # belongs with the sealing decision.
  #
  # Deliberately absent from packer/tests/staging-provisioners.pkr.hcl, which
  # otherwise mirrors this sequence: the harness exists to be run repeatedly
  # against a retained VM, and cleaning up would destroy the thing under test.
  # That divergence is intentional. Do not "fix" it.
  provisioner "powershell" {
    script = abspath("${path.root}/../provisioners/Remove-BuildArtifact.ps1")
    environment_vars = [
      "STAGING_DIR=${var.staging_dir}",
      "GUEST_EVIDENCE_DIR=${var.guest_evidence_dir}",
      "SETUP_ACCOUNT=${var.setup_account_name}",
      "EXPECTED_TIME_ZONE=${var.windows_time_zone}",
      "RESULT_PATH=C:\\Windows\\Temp\\cleanup-result.json"
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "C:\\Windows\\Temp\\cleanup-result.json"
    destination = "${local.evidence_directory}/cleanup-result.json"
  }

  # The seal, first stage (ADR 0002, requirement 2). It runs after the cleanup
  # above because it refuses to go on while a build-time local account exists.
  # It removes only what does not affect WinRM and registers the task that the
  # shutdown command starts; everything that would cut the channel is left to
  # that task. With seal_image false the script changes nothing and records
  # that it was skipped: Packer has no conditional provisioner.
  provisioner "powershell" {
    script = abspath("${path.root}/../provisioners/Invoke-ImageSeal.ps1")
    environment_vars = [
      "SEAL_IMAGE=${var.seal_image}",
      "ADMIN_GROUP_SID=${var.admin_group_sid}",
      "EXECUTION_ID=${var.execution_id}",
      "SETUP_ACCOUNT=${var.setup_account_name}",
      "SEAL_HOLD_SECONDS=${var.seal_hold_seconds}",
      "RESULT_PATH=C:\\Windows\\Temp\\seal-prepare-result.json"
    ]
  }

  # The last thing the build can download. The final stage reports through
  # VMware Tools instead (scripts/runner/verify-seal.sh).
  provisioner "file" {
    direction   = "download"
    source      = "C:\\Windows\\Temp\\seal-prepare-result.json"
    destination = "${local.evidence_directory}/seal-prepare-result.json"
  }
}

