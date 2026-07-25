# AI Instruction

- Version: 7.3
- Last Updated: 2026-07-24
- Project Status: Development / Unstable

This is the canonical AI instruction entry point for the LISA Edge project.
If another repository instruction file conflicts with this file, follow this file unless the user explicitly overrides it in the current task.

## 1. Operating Contract

### Communication

- Chat with the user in Vietnamese.
- Code comments, public APIs, identifiers, function names, variable names, file names, commit messages, and technical documentation must be in English.
- Be direct, practical, security-conscious, and operations-aware.
- Do not over-explain obvious things.
- Explain tradeoffs when they materially affect safety, reliability, recoverability, security, portability, or long-term maintainability.
- Explain the plan before large, destructive, security-sensitive, or non-trivial changes.
- Ask questions only when a missing decision genuinely blocks safe or correct progress.
- After editing, provide a concise file-level summary of what changed.
- Never claim a command, deployment, backup, restore, test, or validation succeeded unless it was actually run.

### Read First

Before non-trivial changes:

1. Read `README.md` for the stable operator interface and repository map.
2. Read the relevant index under `docs/README.md`.
3. Read only the document, README, and implementation nearest to the area being changed.

- Stop reading once sufficient evidence has been gathered.
- Do not read every document blindly. Use indexes and references first.
- Current implementation and explicitly designated canonical documents are authoritative.
- Do not use archived, deprecated, or planned documents as current implementation instructions.
- If documentation conflicts with implementation, identify the conflict instead of silently inventing behavior.

### Compatibility

Follow the canonical Project Status.

Before **Stable** or **Production Ready**, prefer the best current design and do not preserve legacy behavior, formats, data, or backups unless explicitly required.

After **Stable** or **Production Ready**, preserve backward compatibility or provide a documented migration path.

This rule overrides other general compatibility-preservation instructions.

## 2. Immutable Prime Directive

> **Do not reach a conclusion until it can be justified as the best available conclusion under the known constraints, evidence, and project context.**

**Treat every request as a fresh problem**. Do not infer intent from pattern similarity, prior conversational momentum, or the first plausible interpretation. Rebuild your understanding from the current request together with explicit project context.

Before answering, recommending, designing, reviewing, editing, or implementing anything:

### 2.1. **Understand the problem**:

    * Identify what the request is actually asking.
    * Identify relevant constraints, dependencies, risks, and related issues.
    * Verify against existing project documentation, source code, architecture, and other available context when applicable.
    * Do not assume missing intent, requirements, hidden constraints, architecture decisions, naming conventions, or project conventions.

### 2.2. **Explore the solution space**:

    * Reason through a viable approach.
    * When multiple reasonable solutions exist, consider at least one meaningful alternative.
    * Compare approaches using the criteria that matter for the current task, such as correctness, simplicity, maintainability, scalability, long-term project fit, user intent, risk, reversibility, and performance.
    * Do not assume all criteria are equally important.

### 2.3. **Challenge the current best answer**:

    * Actively attempt to find flaws, invalid assumptions, overlooked constraints, or superior alternatives.
    * If a materially better solution is found, replace the current best answer and continue evaluating it.
    * Repeat until no serious flaw remains or further reasoning is unlikely to materially improve the result.
    * Do not optimize for agreement or confirmation. Optimize for the best available conclusion supported by the available evidence and project context, even if it differs from the user's initial preference.

### 2.4. **Conclude only when justified**:

    * Prioritize decision quality over response speed.
    * If information is missing, first use the available project context and the user's explicit intent as the source of truth.
    * Ask a clarifying question only when the missing information materially affects correctness.
    * Otherwise, make the safest minimal assumption, state it explicitly when appropriate, and proceed.
    * If the reasoning limit is reached, return the best answer found so far and clearly identify any remaining uncertainty.

### Execution Discipline

* Default to solutions that are correct, simple, maintainable, and reversible.
* Reject over-engineering, unjustified scope expansion, and unnecessary concepts.
* Default to the smallest change that preserves project integrity.
* For code, documentation, and architecture changes, make the smallest change that completely solves the problem.
* If multiple instructions conflict, follow them in this order: **PRIME DIRECTIVE → Execution Discipline → Project-specific rules.**

### Decision-Making Discipline

* Repository evidence is authoritative. Never substitute inference, convention, or general best practice when repository evidence is available.
* Distinguish observed facts, justified conclusions, assumptions, and recommendations. Do not present one as another.
* Preserve current intent, architecture, public behavior, and established project conventions unless a change is necessary and justified by the task.
* Do not optimize one file, component, or workflow at the expense of repository-wide consistency, operator clarity, security, or recoverability.
* Resolve contradictions using the defined source-of-truth order. When the conflict cannot be resolved safely, identify it explicitly instead of inventing a compromise.
* Default to the smallest complete change. Never choose a smaller change if it leaves the problem incomplete or inconsistent.
* Require a clear, material, long-term benefit before introducing any abstraction, dependency, convention, or architectural layer.
* Maintain existing terminology, interfaces, patterns, and ownership boundaries unless a justified migration is required.
* Separate current implementation, planned capability, historical behavior, and proposed design. Never blur their status.
* Evaluate decisions at both the local and system level. A locally correct change is not acceptable if it weakens the wider architecture or operating model.
* Default to reversible decisions whenever evidence is incomplete or operational impact is uncertain.
* Stop investigating once sufficient evidence supports a safe and well-justified conclusion. Do not continue expanding scope without a material reason.

## 3. Project Identity and Boundary

### Identity

LISA Edge is the lightweight local-infrastructure layer of the LISA ecosystem. It provides connectivity, messaging, service discovery, monitoring, secure remote access, backup, restore, diagnostics, and recovery capabilities that support the broader LISA platform.

LISA Edge is infrastructure for LISA. It supports intelligence but does not replace LISA Brain.

The project should optimize for local availability, secure operation, predictable recovery, maintainability, and hardware independence.

### In Scope

- MQTT and local messaging
- Thread, Matter, OTBR, mDNS, and service discovery support
- NTP / Chrony and supporting infrastructure services
- VPN-first remote administration
- health monitoring and diagnostics
- backup, restore, and disaster recovery
- host bootstrap, hardening, and configuration
- Docker Compose service lifecycle
- integrations that clearly belong at the infrastructure edge

### Explicit Non-Goals

Do not turn LISA Edge into:

- an LLM inference, agent reasoning, planning, or memory platform
- a video analytics, object detection, or transcoding server
- a primary NAS or heavy storage platform
- a large database or analytics host
- an all-in-one server

Small supporting databases or lightweight APIs are acceptable only when their resource use, recovery path, security boundary, and operational value are clearly justified.

### Current Implementation Status
The current implementation is defined by:

```bash
./lisa-edge service list
```
Current examples may include:

- MQTT
- Uptime Kuma
- OpenThread Border Router
- Tailscale
- Home Assistant
- Zigbee2MQTT
- Node-RED

Implemented host-level capabilities:

- Chrony
- host bootstrap
- systemd runtime units
- health checks
- diagnostics
- full-stack backup and restore
- OTBR dataset protection
- production and rescue USB workflows
- independent Rescue OS workflow

Planned but not currently selectable:

- NUT / UPS integration
- DNS helpers
- reverse proxy

Never present a planned service as implemented. Use `./lisa-edge service list` and the current code before claiming deployability.

## 4. Technical and Architectural Direction

### Required Direction

- Linux-first
- Docker-first for application services
- local-first operation
- hardware-agnostic architecture
- Git-managed configuration
- infrastructure as code
- practical immutable infrastructure
- recovery-first operations

Do not replace foundational technology or architecture unless explicitly requested and justified.

### Core Principles

- Prefer reproducible deployment over manual host mutation.
- Prefer externalized persistent data and portable backups.
- Prefer simple, replaceable nodes over unnecessary clustering.
- Preserve security boundaries by default.
- Keep the Rescue Layer independent from production workloads.
- Treat backup and restore as part of every critical service design.

Avoid configuration drift, hidden state, undocumented changes, and snowflake servers.

### Recovery Priority

Use this order:

1. Backup
2. Restore
3. Reliability
4. Failover

A design is incomplete if it cannot explain how it is backed up, restored, rebuilt, diagnosed, and recovered after total production SSD failure.

### Deployment Model

The reference deployment (ZimaBoard 2 1664) is:

```text
eMMC
└── Minimal independent Rescue OS

SSD
└── Production OS, Docker, and persistent service data

NAS or external storage
└── Backup and restore media
```

ZimaBoard 2 is the current reference platform, not an architectural requirement.
The architecture must not depend on ZimaBoard-specific behavior.
Supported deployment targets include, but are not limited to suitable Ubuntu or Debian hosts, mini PCs, NUCs, Raspberry Pi systems, VMs, NAS-hosted VMs, or cloud VMs when the selected images support the CPU architecture.

### Rescue and Production Separation

The Rescue Layer exists for:

- emergency access
- diagnostics
- reinstall automation
- backup restore
- production recovery

It must remain lightweight, independent, stable, and free of normal production workloads.

The Production Layer exists for:

- the production OS
- Docker Engine and Compose
- LISA Edge services
- persistent runtime data
- normal operations

Do not place production services or log-heavy workloads on the Rescue Layer.

### Critical Boundaries

- LISA Edge owns infrastructure services, not AI reasoning.
- LISA Brain owns LLM, ASR/TTS, agent, and orchestration workloads.
- NAS or external storage should own primary backup and archive capacity.
- Vision systems should own heavy camera decoding, detection, and analytics.
- Home automation platforms may integrate with or optionally co-locate on Edge, but their application logic does not redefine the Edge boundary.

## 5. Repository and Source-of-Truth Rules

### Canonical Entry Points

- `./lisa-edge help`: stable operator interface and complete command map
- `README.md`: project entry point, current capabilities, and repository map
- `docs/README.md`: documentation index and operational guidance
- `bash tools/validate-repo.sh`: canonical repository validation used by CI

Users should not need to know where an internal implementation script lives. New operator-facing behavior should normally be exposed through the root CLI.

### Canonical Operator Interface

The root command is the stable operator interface:

```bash
./lisa-edge help
```

Users should not need to know where an implementation script lives.
New operational behavior should normally be exposed through the root CLI instead of requiring users to call internal scripts directly.

Canonical commands include:

- `setup` (interactive configuration, restore, service refresh, bootstrap, and host repair)
- `update` (update repository/images, refresh the stack through the internal engine, verify health)
- `service list`
- `service add <service-key>`
- `service remove <service-key>`
- `service start [service-key ...]`
- `service stop [service-key ...]`
- `security audit [--strict]`
- `security harden`
- `status`
- `health`
- `backup`
- `restore` (service start via `--start-services` / `--no-start-services`)
- `reset data|provisioning|factory`
- `diagnostics`
- `usb list|build|prepare`
- `otbr ...` and `matter ...`
- `rescue`

The root commands `configure`, `bootstrap`, `deploy`, and `stop` do NOT
exist. Do not reintroduce them, and do not add `apply`, `refresh`,
`reconcile`, hidden lifecycle commands, compatibility aliases, or
`service delete`. Host bootstrap (`install/bootstrap/bootstrap.sh`) and the
full-stack deployment engine (`ops/deploy/deploy.sh`) are internal
implementations invoked by setup, update, the service lifecycle,
restore/reset, and systemd — never route them through a root command.

Do not rename, bypass, or duplicate stable commands casually.
Preserve backward-compatible operator behavior unless a breaking change is explicitly justified and documented.

### Canonical Repository Areas

- `install/usb/`: production and rescue installation media
- `install/provisioning/`: first-boot and site-specific provisioning
- `install/bootstrap/`: host packages, hardening, Docker, and storage preparation
- `services/`: service catalog/registry, lifecycle, Compose, configuration, preparation, and provisioning
- `ops/deploy/`: internal deployment engine, update, status, health, and systemd runtime behavior
- `ops/backup-restore/`: backup, restore, archive validation, and timers
- `ops/diagnostics/`: diagnostic collection
- `ops/security/`: read-only security audit and bounded hardening
- `rescue/`: Rescue OS and disaster-recovery tooling
- `docs/`: architecture, operations, security, networking, and procedures
- `tools/`: repository tooling and validation
- `tests/`: structure, unit, security, and integration tests

Use the existing layout. Do not recreate removed legacy layouts such as `scripts/`, `bootstrap/`, `provisioning/`, `usb-installer/`, `recovery/`, `compose/`, `config/`, or `systemd/`.

### Source-of-Truth Precedence

The following precedence is authoritative when determining current behavior:

1. Root CLI behavior and current implementation
2. Current non-archived documentation
3. Planned documentation
4. Archived documentation

Planned documents describe intent, not deployed capability. Archived documents are historical context only.

## 6. Project-Specific Engineering Rules

### Service Design

Prefer Docker Compose for application services.
Use systemd, host packages, or scripts for host-level capabilities when containerization would reduce reliability, obscure ownership, or complicate recovery.

Each critical service should define:

- ownership and boundary
- configuration inputs
- persistent data locations
- secrets handling
- health checks
- restart behavior
- backup scope
- restore procedure
- upgrade behavior
- failure behavior
- resource expectations

Do not add a service only because it is technically possible. Confirm that it belongs on LISA Edge and provides material operational value.

### Resource Discipline

LISA Edge should remain lightweight.
Evaluate CPU, memory, storage, write amplification, log volume, startup behavior, and recovery cost before adding persistent services.

Avoid:

- unbounded logs
- high-frequency writes to eMMC
- large local retention windows
- heavyweight databases without clear need
- unnecessary duplicate services
- polling when event-driven integration is practical

### Networking and Security

Prefer VPN-first administration, SSH key authentication, firewall allow-lists, least privilege, minimal exposed ports, and no public administrative dashboards.

When adding or changing services, evaluate:

- VLAN placement
- firewall direction and ports
- multicast and mDNS requirements
- Thread and Matter discovery
- DNS and NTP dependencies
- VPN reachability
- site-to-site implications
- behavior when WAN or cloud services are unavailable

Never assume one flat LAN. Never weaken VLAN, firewall, or trust boundaries for convenience.

High-sensitivity networks, including access control, alarm, camera, and management networks, require additional scrutiny.

### Automation and Shell

- Maintain existing shell style and helper patterns first.
- Resolve repository paths from script location, not the caller's current directory.
- Quote variable expansions unless intentional splitting is documented.
- Prefer idempotent and safely repeatable operations.
- Preserve meaningful exit codes and send actionable errors to stderr.
- Avoid hidden global state and unjustified dependencies.
- Do not hard-code site-specific IPs, VLANs, hostnames, serials, credentials, or device paths in generic logic.

### Destructive Operations

Disk, partition, filesystem, mount, archive extraction, target-root, and restore operations are safety-critical.

They must:

- validate before mutation
- fail closed on ambiguity
- never guess a disk device name
- protect the running system and mounted production data
- reject traversal and unsafe paths
- make destructive intent visible
- use dry-run or review steps when practical
- clean up safely after failure or cancellation

Prefer serial or explicitly reviewed model matching for installation targets.

### Configuration and Secrets

- Keep `.env`, credentials, private keys, tokens, and runtime secrets outside Git.
- Use restrictive permissions such as `0600` where appropriate.
- Preserve user-managed values unless replacement is explicit.
- Require validation of all mandatory configuration before deployment.
- Default to conservative, portable defaults.
- Treat backup archives as sensitive.
- Never expose secrets through logs, diagnostics, tests, or errors.

### Backup, Restore, and Power Loss

Every critical persistent service must identify what must be backed up and what can be recreated.
Backups must not depend solely on the production SSD.

Restore workflows must validate archives before mutation, reject unsafe content, avoid partial silent success, report exactly what was restored, and define post-restore validation.

Do not claim backup reliability without testing restore.

When changing persistent state, account for power loss, reboot, process termination, missing storage, and unavailable network resources. Prefer atomic writes, temporary staging, checksums, and safely repeatable steps.

### Logging and Diagnostics

Logs and diagnostics should answer:

- What happened?
- Which component failed?
- What input or state caused it?
- What should the operator inspect next?

Avoid noisy output, duplicated messages, secret leakage, and false success states.

## 7. Change Discipline

### General

- Preserve current intent, architecture, and public behavior unless change is justified.
- Make the smallest complete change.
- Do not mix unrelated refactors with feature work.
- Do not reformat or rename unrelated code.
- Do not move files without updating all references and structural tests.
- Do not broaden scope to adjacent services or future plans without need.
- Do not silently convert planned capabilities into implemented ones.
- Update directly affected references, tests, and documentation.

### Refactoring

Before a large refactor:

- identify the operator-facing behavior that must remain stable
- identify affected commands, services, paths, tests, and documentation
- describe migration or compatibility concerns
- produce a short plan

After a refactor, summarize:

- files changed
- responsibilities moved
- behavior preserved
- compatibility impact
- validation performed

### Debugging

When debugging:

- identify observed behavior
- identify expected behavior
- reproduce through the smallest relevant command or test when safe
- trace the root CLI into the smallest relevant implementation path
- identify the root cause
- apply the smallest safe fix
- add a regression test when practical
- mention side effects and recovery considerations

Do not randomly rewrite surrounding automation while fixing one defect.

### Version Control Summary

If the project uses Git or SVN, every response following file changes must include a concise commit description for the completed change.

- Detect version control from repository metadata, configuration, or established project workflow.
- Describe the actual completed change, not the conversation or implementation process.
- Keep every line concise, imperative, and suitable for direct use in a commit message.
- Begin with exactly one plain-language summary line describing the overall completed change.
- The summary line must start directly with the change description.
- Never prefix the summary line with a Conventional Commits type or scope.
- Do not use `type:`, `type(scope):`, or any equivalent prefix on the summary line.
- Follow the summary with bullet entries for each material logical change.
- Every bullet must use a Conventional Commits-style prefix such as `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `chore:`, `perf:`, or `revert:`.
- Use the most specific applicable type and an optional scope for each bullet.
- Use one bullet when the work contains only one material change.
- Do not replace the summary with the bullet list.
- Do not omit the per-change bullets.
- Enclose the entire `Commit description` content in a standalone fenced code block labeled `text`.
- Leave all changes uncommitted by default; Do not run any command that creates or modifies a commit unless the user explicitly requests it.

Required format:

Commit description:

```text
Describe the overall completed change directly without a type or scope prefix.

- type(scope): Describe the first logical change.
- type(scope): Describe each additional logical change when applicable.
```

## 8. Testing and Validation

### Canonical Validation

Run the narrowest relevant tests first, then the canonical validation when practical:

```bash
bash tools/validate-repo.sh
```

The canonical test areas are:

- `tests/structure/` for repository layout, service catalog, stable CLI, and installed paths
- `tests/unit/` for service selection, image policy, and provisioning behavior
- `tests/security/` for archive validation, checksums, mount guards, target-root parsing, and Rescue OS path safety
- `tests/integration/` for complete workflows in isolated temporary filesystem trees

Never claim validation passed unless the command actually completed successfully.

### Test Safety

Tests must:

- resolve `REPO_ROOT` from their own path
- use isolated temporary directories
- never mutate a live host or production data
- never deploy into production paths
- never perform real destructive disk operations
- clean up safely after failure
- include negative tests for security-sensitive behavior

### Validation Expectations

Before finalizing changes, run the narrowest relevant tests first, then the canonical validation when practical.
For operational changes, include safe manual verification steps.
For backup or restore changes, include archive validation and restore-path testing.
For security-sensitive changes, include negative tests that prove unsafe input is rejected.

Never claim validation passed unless the command actually completed successfully.

### Acceptance

A task is complete only when:

- the requested change is implemented
- unrelated files are unchanged
- relevant validation was run or limitations are clearly stated
- directly affected documentation is consistent
- operational, security, or compatibility risks are disclosed
- no untested behavior is presented as verified

## 9. Backup, Restore, and Recovery Rules

### Backup

Every critical persistent service must identify what must be backed up and what can be recreated.
Backups must not depend solely on the production SSD.
Prefer NAS, external storage, or remote encrypted storage as destinations.

Backup workflows should include:

- archive validation
- checksum sidecars
- clear metadata
- safe temporary files
- predictable naming
- cleanup behavior
- failure reporting

### Restore

Restore is a first-class feature, not a documentation afterthought.

Restore workflows must:

- validate the archive before mutation
- reject unsafe paths and malformed content
- preserve or review image references before deploy
- avoid partial silent success
- clearly state what was restored
- identify required post-restore validation

Do not claim backup reliability without testing restore.

### Power Loss and Partial Failure

When changing persistent state, consider interruption by power loss, reboot, process termination, missing storage, or disconnected network resources.
Prefer atomic writes, temporary staging, checksums, resumable or safely repeatable steps, and explicit cleanup.

## 10. Documentation Rules

Documentation is part of the operational interface.

Update documentation when a change affects:

- operator commands
- repository paths
- service availability
- configuration variables
- architecture or boundaries
- security assumptions
- networking requirements
- backup or restore behavior
- recovery procedures
- deployment or validation workflows

Update only directly affected documents.
Do not copy implementation details into multiple documents when one canonical source and links are sufficient.

If implementation and documentation conflict:

1. Mention the conflict.
2. Determine which one represents intended current behavior.
3. Update the incorrect source when within scope.
4. Never silently preserve contradictory instructions.

## 11. Standard Response Formats

After making changes:

```text
Summary:
- ...

Files changed:
- ...

Validation:
- ...

Operational impact:
- ...

Notes:
- ...
```

For analysis-only tasks:

```text
Findings:
- ...

Recommendation:
- ...

Risk:
- ...
```

For architecture review:

```text
Architecture assessment:
- ...

Strengths:
- ...

Risks:
- ...

Recommended changes:
- ...

Score:
- ...
```

## 12. Priority Order

When priorities conflict:

1. Safety
2. Correctness
3. Recoverability
4. Security
5. Reliability
6. Maintainability
7. Portability
8. Operator clarity
9. Performance
10. Developer convenience

For destructive storage, restore, networking, security, and production deployment work, safety and recoverability come first.
