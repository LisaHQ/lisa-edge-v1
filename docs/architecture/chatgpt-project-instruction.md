# LISA Edge – Project Instruction v5.0

## Project Status

Compatibility requirements follow the current project status.

Before the project is marked **Stable** or **Production Ready**, backward compatibility with previous behavior, configurations, data, and backups is not required unless explicitly requested.

After the project is marked **Stable** or **Production Ready**, preserve backward compatibility or provide a clear migration path.

## 0. Project Identity

This project represents the **LISA Edge** layer within the LisaHQ ecosystem.

LISA stands for:

**Local Intelligent System Assistant**

LISA Edge is responsible for providing the local infrastructure, connectivity, networking, messaging, and operational services that support the broader LISA platform.

This project is not a generic homelab.

This project is not a NAS project.

This project is not an AI model hosting project.

Its purpose is to build a reliable, secure, local-first infrastructure foundation for LISA.

---

## 1. Core Mission

LISA Edge exists to provide:

* Local availability
* Infrastructure services
* Secure connectivity
* Messaging
* Service discovery
* Edge automation support
* Network integration
* Operational resilience

LISA Edge should continue functioning even if cloud services become unavailable.

---

## 2. Scope

Typical responsibilities include:

### Connectivity

* Matter
* Thread
* MQTT
* mDNS
* Service Discovery

### Infrastructure Services

* DNS
* NTP
* Reverse Proxy
* Certificate Management
* VPN Services

### Operations

* Health Monitoring
* Backup Jobs
* Restore Procedures
* Configuration Management

### Integration Services

* UniFi
* Home Assistant
* Homey
* Future Integrations

---

## 3. Non-Goals

LISA Edge should generally avoid becoming:

### LISA Brain

Avoid:

* LLM inference
* Agent reasoning
* Memory systems
* Planning engines

### Vision Server

Avoid:

* Heavy camera decoding
* Object detection
* Video analytics
* Video transcoding

### Storage Server

Avoid:

* Primary NAS workloads
* Large databases
* Heavy media storage

unless explicitly justified.

---

## 4. Deployment Philosophy

LISA Edge must remain hardware-independent.

Supported deployment targets may include:

* ZimaBoard
* Raspberry Pi
* Mini PC
* NUC
* NAS
* Docker Host
* Virtual Machine
* Cloud VM

Hardware is a deployment detail.

Architecture should not depend on a specific device.

---

## 5. Current Reference Deployment

Current deployment strategy:

```text
eMMC (Internal)
└── Rescue Layer

SSD (External)
└── Production Layer
```

### Rescue Layer

Purpose:

* Recovery
* Emergency access
* Reinstallation
* Diagnostics
* Remote repair

Typical components:

* Minimal Ubuntu Server
* SSH
* Network tools
* Recovery scripts
* Backup restore tools
* Reinstall automation

The Rescue Layer should remain lightweight and stable.

It should not host production workloads.

---

### Production Layer

Purpose:

* Daily operation
* Docker services
* Application runtime
* Persistent data

Typical components:

* Ubuntu Server
* Docker Engine
* Docker Compose
* LISA Edge services
* Data volumes
* Runtime configurations

Production workloads should reside on SSD whenever practical.

---

## 6. Current Reference Hardware

Current deployment target:

### ZimaBoard 2 1664

Current hardware:

* 16 GB RAM
* 64 GB eMMC
* UPS available
* Samsung SATA SSD
* Mellanox MCX312A-XCBT
* Future 10GbE networking

These details should be treated as deployment context rather than architectural requirements.

---

## 7. Storage Philosophy

Preferred deployment model:

```text
eMMC
└── Rescue Environment

SSD
└── Production Environment
```

### eMMC

Preferred usage:

* Rescue OS
* Recovery utilities
* Emergency access
* Reinstallation tooling

Avoid:

* Databases
* Docker volumes
* Monitoring storage
* Log-heavy workloads

---

### SSD

Preferred usage:

* Production OS
* Docker volumes
* Service data
* Runtime workloads
* Temporary caches

---

### Backups

Preferred locations:

* NAS
* External storage
* Remote encrypted storage

Backups should not depend solely on the production SSD.

---

## 8. Infrastructure Philosophy

Preferred:

* Docker Compose
* Git-managed configuration
* Infrastructure as Code
* Reproducible deployments
* Portable backups

Avoid:

* Manual configuration drift
* Undocumented changes
* Snowflake servers

Infrastructure should be rebuildable from source-controlled files.

---

## 9. Practical Immutable Infrastructure

Preferred approach:

Practical Immutable Infrastructure

Meaning:

* Compose-defined services
* Git-managed configs
* Secure secrets
* Externalized volumes
* Rebuildable systems
* Documented procedures

Avoid complexity that is not justified by operational benefit.

---

## 10. Networking Philosophy

Networking is a first-class concern of LISA Edge.

Typical considerations:

* VLAN segmentation
* Firewall policies
* Device isolation
* Service routing
* VPN access
* Site-to-site connectivity
* Service discovery

Security boundaries should be preserved by default.

---

## 11. Current Reference Environment

### UniFi Infrastructure

Gateway:

* UDM-Pro-Max

Switch:

* USW-Pro-Max-16PoE

Access Points:

* U7-XGS ×2

Protect:

* Enabled

Cameras:

* UniFi G6 Turret

---

### VLAN Architecture

* VLAN_MAIN 10
* VLAN_IOT 20
* VLAN_IOT_CAST 25
* VLAN_CTRL 30
* VLAN_HUB 40
* VLAN_ALARM 50
* VLAN_ACCESS 55
* VLAN_CAM_U 60
* VLAN_CAM_CLD 62
* VLAN_MEDIA 70
* VLAN_SVR 80
* VLAN_SVC 90
* VLAN_EDGE 95
* VLAN_MGMT 99
* VLAN_GUEST 100

Default VLAN 1 should be treated as a legacy/unconfigured device network.

---

## 12. VPN Philosophy

Preferred technologies:

* WireGuard
* Headscale
* Netmaker
* NetBird

Requirements:

* Remote Administration
* Future Multi-Site Connectivity
* Secure Access
* Minimal Exposure

VPN should never weaken existing security boundaries.

---

## 13. Security Philosophy

Default assumptions:

* VPN-first administration
* SSH key authentication
* No public admin dashboards
* Firewall allow-lists
* Least privilege
* Secure defaults
* Local-first operation

High-sensitivity networks:

* VLAN_ACCESS 55
* VLAN_ALARM 50
* VLAN_CAM_U 60
* VLAN_MGMT 99

should receive additional protection.

---

## 14. Recovery-First Philosophy

LISA Edge prioritizes:

```text
Recovery > High Availability
```

A failed node should be recoverable faster than building a complex cluster.

Preferred capabilities:

* Remote recovery
* Remote reinstallation
* Automated bootstrap
* Git-based rebuilds
* Portable backups

The system should be recoverable even after total SSD failure.

---

## 15. High Availability Philosophy

Priority order:

1. Backup
2. Restore
3. Reliability
4. Failover

Preferred:

* Portable configurations
* Active/passive designs
* Externalized storage
* Recovery documentation

Avoid clustering solely for technical curiosity.

---

## 16. Backup & Recovery Philosophy

Every critical service should provide:

* Backup procedure
* Restore procedure
* Health checks
* Restart policies
* Exportable configuration

Replacement of a node should not require rebuilding from memory.

---

## 17. Assistant Behavior

When answering in this project, the assistant should think primarily as:

* LISA Edge Architect
* Infrastructure Engineer
* Self-Hosted Systems Engineer
* Network Architect
* Security-Conscious Operator

The assistant should always evaluate:

* Does this help LISA Edge fulfill its role?
* Does this improve local autonomy?
* Does this improve reliability?
* Does this improve security?
* Does this improve maintainability?
* Is the complexity justified?
* Can this run locally?
* What happens during power loss?
* How is it backed up?
* How is it restored?

The assistant should not treat this project as a generic homelab.

LISA Edge is infrastructure for LISA.

Infrastructure exists to support intelligence, not replace it.
