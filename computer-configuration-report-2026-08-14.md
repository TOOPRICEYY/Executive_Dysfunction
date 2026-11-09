# Current Computer Configuration Report

**Captured:** August 14, 2026, 4:08–4:10 PM EDT  
**Collection mode:** Live, local, read-only inspection  
**Privacy:** Unique identifiers and personal network details were intentionally omitted  
**Changes made:** No system settings changed; only this report file was created

## Executive summary

This is a high-end Apple-silicon development system: a MacBook Pro with an Apple M4 Pro, a 14-core CPU, a 20-core GPU, 48 GB of unified memory, and a 2 TB internal NVMe SSD. It is running macOS 26.3.1(a) with a broad modern development toolchain.

The storage data volume is 75% used, with about 500 GB available. Battery health is reported as normal at 94% of original maximum capacity after 160 cycles. During collection, macOS reported AC power connected while the battery remained at 22–23% and discharging; that sampled inconsistency is worth rechecking with the charger and cable.

System Integrity Protection, Gatekeeper, and automatic security updates are enabled. The macOS Application Firewall and stealth mode are disabled, and the `xprotect` utility reports both launch and background scans disabled. FileVault status could not be verified from the restricted inspection session.

## Hardware

| Component | Current configuration |
|---|---|
| Computer | MacBook Pro |
| Model identifier | Mac16,8 |
| Architecture | Apple silicon / arm64 |
| Processor | Apple M4 Pro |
| CPU | 14 cores: 10 performance + 4 efficiency |
| GPU | Integrated 20-core Apple M4 Pro GPU |
| Graphics API | Metal supported |
| Unified memory | 48 GB LPDDR5, reported manufacturer Micron |
| Internal storage | APPLE SSD AP2048Z, nominal 2 TB NVMe |
| Storage features | Internal, non-detachable, TRIM enabled |
| Firmware / OS loader | 13822.81.10 |
| Display | Active panel details were not exposed in this restricted session |

## Storage and live system state

| Metric | Sampled value |
|---|---:|
| APFS Data volume capacity | 1.995 TB formatted |
| APFS Data volume used | 1.433 TB |
| APFS Data volume available | 500 GB |
| APFS Data volume utilization | 75% |
| macOS memory-pressure free percentage | 66% |

The memory-pressure figure is macOS's system-wide pressure metric, not a literal count of unused RAM. Storage values are rounded decimal figures reported by `df`; APFS shared-container, reserved, snapshot, and filesystem categories mean the displayed used and available values need not visibly sum to the displayed capacity. The Data volume is the meaningful utilization view, and the sealed system volume should not be added to it as if it were a separate physical disk.

## Battery and power

| Item | Current configuration / sample |
|---|---|
| Battery condition | Normal |
| Maximum capacity | 94% |
| Cycle count | 160 |
| Charge during capture | 22–23% |
| Sampled state | Discharging, despite AC/charger being reported connected |
| Estimated remaining time | Approximately 1 hour 38 minutes to 1 hour 58 minutes across samples |
| Low Power Mode on AC | Off |
| System sleep on AC | 1 minute |
| Display sleep on AC | 10 minutes |
| Disk sleep on AC | 10 minutes |
| Wake on LAN | Enabled |
| Hibernate mode | 3 |

The charge-state mismatch is an observation, not a diagnosis. It can occur with an underpowered adapter, a cable/port issue, power demand exceeding adapter output, or transient power-management behavior.

## Operating system and development environment

| Area | Installed configuration |
|---|---|
| Operating system | macOS 26.3.1(a), build 25D771280a |
| Kernel | Darwin 25.3.0, arm64 |
| Default shell | zsh 5.9 |
| Xcode | 26.4.1 (17E202) |
| Apple clang | 21.0.0 |
| Swift | 6.3.1 |
| Git | Apple Git 2.50.1 |
| Python | 3.14.0; pyenv 2.6.26; pip 25.1; uv 0.11.6 |
| JavaScript | Node.js 25.6.1; npm/npx 11.9.0; pnpm 10.26.1 |
| Go | 1.25.5, darwin/arm64 |
| Ruby | 2.6.10 |
| Package/build tools | Homebrew 6.0.2; GNU Make 3.81 |
| Containers | Docker Desktop 4.54.0; Docker CLI 29.1.2; Compose 2.40.3 |
| Kubernetes tools | kubectl 1.34.1; Helm 4.1.4 |
| Virtualization | Apple Virtualization and Hypervisor frameworks present; Rosetta 2 installed |

Docker Desktop is configured with Kubernetes enabled and 24,320 MiB of memory. Its daemon was not reachable during collection, which is consistent with Docker Desktop being stopped or unavailable to the restricted session. Java's launcher exists, but no Java Runtime was available. Rust/Cargo, .NET, PHP, CMake, Ninja, Bun, Deno, and Yarn were not found on the active command path.

## Security posture

| Control | Observed state |
|---|---|
| System Integrity Protection (SIP) | Enabled |
| Gatekeeper app assessment | Enabled |
| macOS Application Firewall | **Disabled** |
| Firewall stealth mode | Off |
| Automatic update checking | Enabled |
| Automatic downloads | Enabled |
| Automatic macOS updates | Enabled |
| Critical and configuration-data updates | Enabled |
| XProtect version | 5347, reported installed June 3, 2026 |
| XProtect scan status | **Launch scans disabled; background scans disabled** |
| FileVault | Unknown—could not be queried in this session |
| PF packet filter | Unknown—access denied by the restricted session |
| Remote Login / Remote Apple Events | Unknown—administrator access required |

The firewall's signed-software exceptions are configured to allow Apple-signed and downloaded signed apps automatically if firewall enforcement is enabled. XProtect scan state is the direct output of `xprotect status`; this report does not diagnose why both modes are disabled. The report also did not compare the installed XProtect version with Apple's latest release, so it does not claim that version 5347 is current.

## Network snapshot

- At least one physical-class network interface reported an active link.
- The default IPv4 route used a tunnel-class interface during capture. This suggests an active network-extension, privacy-relay, or VPN-style path, but the specific product or service was deliberately not identified.
- One legacy macOS VPN service was configured but disconnected; this does not rule out a separate network-extension tunnel.
- HTTP, HTTPS, FTP, SOCKS, PAC, and WPAD system proxies were all disabled.
- DNS details and the physical interface's Wi-Fi/Ethernet mapping were unavailable to the restricted session.

## Items worth reviewing

1. Investigate why XProtect reports both launch and background scans disabled.
2. Decide whether the macOS Application Firewall should be enabled for this computer's threat model.
3. Verify FileVault in **System Settings → Privacy & Security → FileVault**.
4. Recheck why the battery reports discharging while an AC charger is connected.
5. Keep an eye on storage growth: about 500 GB remains available, with the Data volume at 75% utilization.

## Collection speed and methodology

The first core inventory pass completed in **1.3 seconds**. Parallel hardware, software, storage, power, security, and network cross-checks completed in approximately **2 minutes 10 seconds** (4:08:14–4:10:24 PM EDT), before report assembly. The complete roughly 1,200-word report—including assembly, a privacy scan, independent QA, one extra XProtect verification, and corrections—was ready in **4 minutes 48 seconds** end to end.

Evidence came from macOS's read-only reporting interfaces, including `system_profiler`, `sw_vers`, `uname`, `df`, `pmset`, `memory_pressure`, `csrutil`, `spctl`, the Application Firewall utility, Software Update preferences, XProtect's version utility, and version commands for installed developer tools. Checks that required administrator access, DiskManagement access, or restricted kernel interfaces were labeled unknown rather than inferred.

Serial numbers, hardware and volume UUIDs, MAC and IP addresses, SSIDs, hostnames, usernames, interface numbers, VPN/service names, certificates, and personal volume labels are excluded from this report.
