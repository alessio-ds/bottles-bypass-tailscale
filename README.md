# Bottles Bypass Tailscale

Run [Bottles](https://usebottles.com/) (Flatpak) on Linux while **bypassing a Tailscale exit node**, so traffic exits directly through your real network interface.

## The Problem

When a Tailscale exit node is active, **all** traffic is routed through it — including applications running in Bottles (Wine/Proton). Some services (like KakaoTalk) detect the exit node's IP and block it, or behave incorrectly because of the unexpected network path.

Disabling the exit node globally isn't an option if you need Tailscale for other things.

## The Solution

This script creates an **isolated Linux network namespace** with its own veth pair and NAT, then launches Bottles inside it. Traffic from the namespace bypasses Tailscale's policy routing and exits directly through your physical interface (`wlp3s0`, `eth0`, etc.).

```
┌─────────────────────────────────────────────────┐
│  Network Namespace (kt-bypass)                  │
│                                                 │
│  KakaoTalk (Wine) ──► veth-kt-n ──► NAT ──────┐│
│                                                 ││
└─────────────────────────────────────────────────┘│
                                                   │
                    ┌──────────────────────────────┘
                    ▼
              veth-kt-h ──► wlp3s0 ──► Internet
                    (bypass Tailscale)
```

Key technical details:
- **nftables bypass table** at priority `filter - 5` / `srcnat - 1` (before firewalld)
- **Policy routing rule** `from 10.200.0.0/24 lookup main priority 5269` to bypass Tailscale's `table 52`
- **IPv6 disabled** in the namespace to prevent timeout fallback delays
- **DNS** set to `1.1.1.1` inside the namespace (isolated from host's systemd-resolved)
- **`nsenter --net --mount`** ensures the correct `resolv.conf` is visible to the application

## Requirements

- Fedora (or similar RPM/DEB-based distro) with:
  - `firewalld` with nftables backend
  - `nftables`
  - `iproute2`
- Flatpak with Bottles installed (`com.usebottles.bottles`)
- Tailscale with an exit node configured
- Root access (for namespace and firewall setup)

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/bottles-bypass-tailscale.git
cd bottles-bypass-tailscale
chmod +x bottles-bypass-tailscale.sh
```

Optionally, install system-wide:

```bash
sudo cp bottles-bypass-tailscale.sh /usr/local/bin/bottles-bypass-tailscale
```

## Usage

### First-time setup

```bash
sudo ./bottles-bypass-tailscale.sh --setup
```

This creates the network namespace, veth pair, nftables rules, and firewall zone. It persists until reboot or manual cleanup.

### Launch Bottles (bypass Tailscale)

```bash
sudo ./bottles-bypass-tailscale.sh
```

The script auto-runs setup if the namespace doesn't exist. It will:
1. Verify the public IP (should be your real IP, not the exit node)
2. Launch Bottles via `flatpak run` with the correct environment

### Check status

```bash
sudo ./bottles-bypass-tailscale.sh --check
```

### Cleanup (remove everything)

```bash
sudo ./bottles-bypass-tailscale.sh --cleanup
```

## Configuration

All settings can be overridden via environment variables:

| Variable | Default | Description |
|---|---|---|
| `HOST_IFACE` | *(auto-detected)* | Outgoing network interface |
| `NS_NAME` | `kt-bypass` | Network namespace name |
| `DNS_SERVER` | `1.1.1.1` | DNS server inside the namespace |
| `FLATPAK_APP` | `com.usebottles.bottles` | Flatpak application ID |
| `BOTTLE_NAME` | `chat` | Bottles bottle name |
| `PROGRAM_NAME` | `KakaoTalk` | Program to launch in Bottles |

Example:

```bash
sudo HOST_IFACE=enp0s3 PROGRAM_NAME=Discord BOTTLE_NAME=gaming \
  ./bottles-bypass-tailscale.sh
```

## Desktop Entry

To create a launcher for your desktop environment:

```bash
cat > ~/.local/share/applications/bottles-nots.desktop << 'EOF'
[Desktop Entry]
Name=Bottles (No Tailscale)
Comment=Run Bottles bypassing Tailscale exit node
Exec=sudo /path/to/bottles-bypass-tailscale.sh
Icon=applications-other
Terminal=true
Type=Application
Categories=Utility;
EOF

update-desktop-database ~/.local/share/applications/
```

> **Note:** `Terminal=true` is required because the script needs root (sudo). For passwordless sudo, add a rule:
> ```
> echo "youruser ALL=(ALL) NOPASSWD: /path/to/bottles-bypass-tailscale.sh" | sudo tee /etc/sudoers.d/bottles-nots
> ```

## How It Works

### Network Isolation

1. A **network namespace** (`kt-bypass`) is created with a veth pair connecting it to the host
2. The host-side veth (`veth-kt-h`) gets IP `10.200.0.1/24`, the namespace-side gets `10.200.0.2/24`
3. **Masquerade (SNAT)** is applied to all traffic from `10.200.0.0/24` going out through the physical interface

### Bypassing Tailscale

Tailscale installs a policy routing rule:
```
5270: from all lookup 52
```
This forces all forwarded traffic into `table 52` (which routes through `tailscale0`).

The script adds a **higher-priority rule** (5269 < 5270):
```
5269: from 10.200.0.0/24 lookup main
```
This tells the kernel: "traffic from the namespace subnet uses the main routing table instead." Result: traffic exits through `wlp3s0` directly.

### Beating firewalld

Fedora's `firewalld` uses nftables with priority `filter` (0) and `srcnat` (0). The bypass table is inserted at **lower numeric priorities** (`filter - 5` and `srcnat - 1`) so its rules are evaluated first, before firewalld can drop forwarded packets.

### DNS and IPv6

- The namespace uses `nameserver 1.1.1.1` instead of the host's `127.0.0.53` (systemd-resolved stub), which is unreachable from the namespace
- IPv6 is disabled in the namespace (`net.ipv6.conf.all.disable_ipv6=1`) to prevent connection timeouts when the client tries IPv6 addresses that have no route

## Troubleshooting

**"No such file or directory" when running without sudo:**
The script requires root. Use `sudo`.

**Namespace already exists after reboot:**
Namespaces don't survive reboots. The script auto-recreates them, or run `--setup` manually.

**Firewall blocks forwarded traffic:**
Make sure the bypass nft table is active:
```bash
sudo nft list table inet bypass
```
If missing, run `--setup` again.

**DNS resolution fails inside the namespace:**
Verify the namespace's resolv.conf:
```bash
sudo ip netns exec kt-bypass cat /etc/resolv.conf
```
It should show `nameserver 1.1.1.1`.

## License

MIT
