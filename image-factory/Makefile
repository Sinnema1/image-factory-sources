SHELL := /usr/bin/bash

PACKER_TEMPLATE := ./packer/templates/windows-11-vsphere.pkr.hcl
PACKER_VARS := ./configs/windows-11-vsphere.pkrvars.hcl
PACKAGE_VARS := ./build/package-vars.pkrvars.hcl

.PHONY: help init fmt validate-packer stage-packages verify-iso-datastore validate preflight build-diagnostic publish list-evidence collect-evidence status list-vms clean-vm evidence-dir

help:
	@printf '%s\n' \
	"Available commands:" \
	"    make init              Install required Packer plugins" \
	"    make fmt               Check Packer formatting" \
	"    make validate-packer   Verify the install inputs, then validate the Packer configuration" \
	"    make stage-packages    Verify the lock, package-runner and the package files on the" \
	"                           runner, as the build does before Packer starts" \
	"    make verify-iso-datastore  Verify the ISO on the vSphere datastore against its" \
	"                           record (workstation only: needs govc. Streams the whole ISO)" \
	"    make validate          Validate ISO and Packer configuration (workstation only:" \
	"                           needs the software share mounted)" \
	"    make preflight         Run runner and repository checks (workstation only: needs govc)" \
	"    make build-diagnostic  Run a retained diagnostic build" \
	"    make publish           Build, seal, snapshot and record a master image (CI)" \
	"    make list-evidence     List collected evidence files" \
	"    make collect-evidence  Write evidence/index.json and SHA256SUMS" \
	"    make status            Show repository and tool status" \
	"    make list-vms          List candidate Packer test VMs (workstation only: needs govc)" \
	"    make clean-vm VM_NAME=<name>  Delete one Packer test VM from disk" \
	"                           (workstation only: needs pwsh and VMware PowerCLI)" \
	"    make evidence-dir      Create the evidence/ directory"

init:
	packer init $(PACKER_TEMPLATE)

fmt:
	packer fmt -check -recursive ./packer

validate-packer: evidence-dir
	@bash ./scripts/runner/stage-packages.sh --emit-var-file $(PACKAGE_VARS)
	packer validate -var-file=$(PACKER_VARS) -var-file=$(PACKAGE_VARS) $(PACKER_TEMPLATE)

stage-packages: evidence-dir
	@bash ./scripts/runner/stage-packages.sh

# Stage 2 of ISO qualification: hashes the copy the build actually boots.
# Override the record with METADATA=<file>, for example the VMware Tools record.
#
# Sources .env for the vCenter credentials, the same way build-diagnostic does.
# Without it the script stops on require_env even when .env holds the values.
verify-iso-datastore: evidence-dir
	@if [[ -f ".env" ]]; then \
		set -a; source ./.env; set +a; \
	fi; \
	bash ./scripts/runner/verify-datastore-iso.sh $(if $(METADATA),--metadata $(METADATA))

validate: evidence-dir
	@./scripts/runner/validate.sh

preflight:
	@./scripts/runner/preflight.sh

build-diagnostic: evidence-dir
	@if [[ -f ".env" ]]; then \
		set -a; source ./.env; set +a; \
	fi; \
	./scripts/runner/build-diagnostic.sh

# Builds, seals, snapshots and records a master image (ADR 0005). CI only in
# practice: it needs govc and download-packages, and a job id for the version.
publish: evidence-dir
	@if [[ -f ".env" ]]; then \
		set -a; source ./.env; set +a; \
	fi; \
	./scripts/runner/publish-image.sh

list-evidence:
	@find ./evidence -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort

collect-evidence: evidence-dir
	@bash ./scripts/runner/collect-evidence.sh

status:
	@printf 'Git commit: '
	@git rev-parse --short HEAD
	@packer version
	@packer plugins required $(PACKER_TEMPLATE)
	@git status -sb

# Lists the VMs that clean-vm could delete. Override the pattern with
# VM_NAME_PATTERN=<glob>. Needs govc, so this is a workstation target.
list-vms:
	@./scripts/runner/check-vm-name.sh $(VM_NAME_PATTERN)

# Deletes exactly one VM, including its files. Requires an exact name:
#   make clean-vm VM_NAME=<name>           asks for confirmation
#   make clean-vm VM_NAME=<name> FORCE=1   no prompt
# List candidates with `make list-vms`.
clean-vm:
	@test -n "$(VM_NAME)" || { echo "ERROR: set VM_NAME=<exact VM name>."; exit 1; }
	@case "$(VM_NAME)" in *[!A-Za-z0-9._-]*) echo "ERROR: VM_NAME may only contain letters, digits, '.', '_' and '-'."; exit 1;; esac
	@pwsh -NoLogo -NoProfile -File ./scripts/windows/Remove-PackerTestVm.ps1 -VMName "$(VM_NAME)" $(if $(FORCE),-Force)

evidence-dir:
	@mkdir -p evidence