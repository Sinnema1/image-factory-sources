# Example Labs vSphere Discovery

> **Partly superseded.** This document was written when ISO consumption was expected to go
> through the vSphere Content Library. The build now references each ISO by **datastore
> path**, read from its qualification record in `packer/sources/windows/` (ADR 0004); see the
> Key Decisions in `README.md`. Content Library access was re-checked on 2026-09-28 and returns
> `403`; the cause is recorded in ADR 0005. The Content Library sections below are retained as discovery notes, not as a
> statement of how the build works. The vCenter, cluster, datastore and network values remain
> current.

## Purpose

This document records environment-specific vSphere values required to support:

- STORY-15 - ISO Consumption (originally from Content Library; now datastore-backed)
- STORY-16 - Packer Build VM Foundation

This document is intended for discovery and troubleshooting and should not contain passwords, secrets, or tokens.

---

# Environment Status

| Item | Status | Note |
|-------|-------|-------|
| vCenter Access | **Confirmed** | POST /api/session works with Basic Auth. Session ID returned successfully. |
| Content Library Access | **Blocked** | GET /api/content/library returns 404. Requires permissions. Re-checked 2026-09-28: `403`; cause and fix in ADR 0005. |
| VM Provisioning Permission | **Confirmed** | Packer creates, builds and shuts down a VM in the project folder from CI on every build (most recent: job 3859, 2026-10-02). The role and how it is held are in ADR 0005. |
| Shared Software Catalog Access | Confirmed |  `\\fileshare\shared\image-factory\` |
| GitLab Access | Confirmed | SSH key configured |
| Developer Workstation | Ready | Toolchain installed and validated |

---

# vCenter

## vCenter Server

| Property | Value |
|----------|----------|
| URL | `https://vcenter.example.test` |
| FQDN | `vcenter.example.test` |
| Port | 443 |
| API Base Path | `/api` |
| Notes | Session-based authentication via `vmware-api-session-id` header |

---

# Authentication

| Property | Value |
|----------|----------|
| User Account | `EXAMPLE.TEST\builduser` |
| Service Account | TBD |
| Authentication Method | Basic Auth (username/password) for session creation |
| Session Header | `vmware-api-session-id` |
| Notes | Session endpoint: POST /api/session |

---

# Datacenter

| Property | Value |
|----------|----------|
| Datacenter Name | **Confirmed via GET /api/vcenter/datacenter** |
| Notes | Access confirmed. Endpoint returns list of datacenters. |

---

# Cluster

| Property | Value |
|----------|----------|
| Cluster Name | **Confirmed via GET /api/vcenter/cluster** |
| Notes | Access confirmed. Endpoint returns list of clusters. |

---

# Datastore

| Property | Value |
|----------|----------|
| Datastore Name | **Confirmed via GET /api/vcenter/datastore** |
| Type | TBD |
| Notes | Access confirmed. Endpoint returns list of datastores. |

---

# Network

## Build Network

| Property | Value |
|----------|----------|
| Port Group | **Confirmed via GET /api/vcenter/network** |
| VLAN | TBD |
| DHCP Available | TBD |
| DNS Available | TBD |
| Notes | Access confirmed. Endpoint returns list of networks. |

---

# VM Placement

## Folder

| Property | Value |
|----------|----------|
| VM Folder | **Confirmed via GET /api/vcenter/folder** |
| Notes | Access confirmed. Endpoint returns list of VM folders. |

---

## Resource Pool

| Property | Value |
|----------|----------|
| Resource Pool | TBD |
| Notes | Access not yet validated. |

---

# Content Library

## Library Details

| Property | Value |
|----------|----------|
| Library Name | **Blocked** |
| Library Type | Local / Subscribed |
| Notes | GET /api/content/library returns 404. May require additional permissions or disabled service. |

---

# Windows Installation Media

## Approved ISO

| Property | Value |
|----------|----------|
| Operating System | TBD |
| Edition | TBD |
| Version | TBD |
| Architecture | TBD |
| Content Library Item | **Blocked (see Content Library section)** |
| Source | MSDN / Visual Studio Subscription / Other |
| Notes | Content Library access required for ISO discovery. |

### Initial Request

Current expectation:

- Windows 11 Enterprise
- x64
- English (US)

Final version pending confirmation

---

# Packer Discovery

## Plugin Strategy

| Property | Value |
|----------|----------|
| Plugin Acquisition Method | Direct Internet Download |
| Local Mirror Required | No |
| Offline Installation Required | No |
| Notes | Workstation can access Internet resources |

## Development Workstation

| Property | Value |
|----------|----------|
| Developer Workstation | workstation-01 |
| Packer Installed | Yes |
| Packer Version | 1.16.0 |
| Internet Access Available | Yes |
| Status | Operational |

## Required Plugins

### vSphere

| Property | Value |
|----------|----------|
| Plugin | github.com/vmware/vsphere |
| Version | 2.4.0, pinned in the template's `required_plugins` |
| Installed | By `packer init` in every CI job that needs it |
| Verification | Every successful build |

## Expected Builder

```hcl
source "vsphere-iso" "windows-11" {}
```

Status:
- The plugin is installed and the builder is in use: `packer/templates/windows-11-vsphere.pkr.hcl`.
- vCenter API access **confirmed** for building (see Environment Status); Content Library access is still blocked.

---
# Temporary Build VM

# Naming Convention

Example:

```text
lab-build-w11-001
```

| Property | Value |
|----------|----------|
| Naming Convention | TBD |
| Guest OS Type | TBD |
| CPU Count | TBD |
| Memory | TBD |
| Disk Size | TBD |
| Notes | VM creation (POST /api/vcenter/vm) untested. |

---
# Active Sprint Dependencies

## STORY-15

### Required
- VM creation permissions
- Datastore identification
- Network identification
- Folder/resource-pool identification

### Current Status
Unblocked. The build creates its VM through the vCenter API (see Environment Status). Content Library access remains blocked and is not needed: the build reads its ISOs by datastore path (ADR 0004).

---
# Meeting Notes

## 2026-08-12

### Confirmed
- Example Labs provides Windows licensing
- Example Labs can provide Windows ISOs.
- Existing VDI pilot OU and service account may be reusable.
- Mock software catalog will use file shares.
- Additional VMware backend configuration is required before provisioning activities can begin.

### Pending
- vCenter access (**Resolved: Confirmed**)
- Content Library discovery (**Blocked: 404**)
- Provisioning role assignment (**Partial: GET confirmed**)
- Network/VLAN details (**Partial: GET confirmed**)
- AI API token confirmation