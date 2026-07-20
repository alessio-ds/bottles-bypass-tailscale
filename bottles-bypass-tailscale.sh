#!/bin/bash
#
# bottles-bypass-tailscale.sh
# Run Bottles (Flatpak) while bypassing a Tailscale exit node.
#
# Creates an isolated network namespace with NAT that routes traffic
# directly through the physical interface, bypassing Tailscale entirely.
#
# Usage:
#   sudo bottles-bypass-tailscale.sh --setup
#   sudo bottles-bypass-tailscale.sh
#   sudo bottles-bypass-tailscale.sh --cleanup
#   sudo bottles-bypass-tailscale.sh --check
#
# Environment variables:
#   HOST_IFACE    - Outgoing interface (auto-detected if not set)
#   NS_NAME       - Namespace name (default: kt-bypass)
#   DNS_SERVER    - DNS server in namespace (default: 1.1.1.1)
#   FLATPAK_APP   - Flatpak app ID (default: com.usebottles.bottles)
#   BOTTLE_NAME   - Bottles bottle name (default: chat)
#   PROGRAM_NAME  - Program name in Bottles (default: KakaoTalk)

set -euo pipefail

NS_NAME="${NS_NAME:-kt-bypass}"
VETH_HOST="veth-kt-h"
VETH_NS="veth-kt-n"
SUBNET="10.200.0.0/24"
HOST_IP="10.200.0.1"
NS_IP="10.200.0.2"
HOST_IFACE="${HOST_IFACE:-}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
IP_RULE_PRIO=5269
FLATPAK_APP="${FLATPAK_APP:-com.usebottles.bottles}"
BOTTLE_NAME="${BOTTLE_NAME:-chat}"
PROGRAM_NAME="${PROGRAM_NAME:-KakaoTalk}"

REAL_USER="${SUDO_USER:-$USER}"

_detect_iface() {
    if [ -n "$HOST_IFACE" ]; then
        return
    fi
    HOST_IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    if [ -z "$HOST_IFACE" ]; then
        echo "Error: cannot detect default interface. Set HOST_IFACE env var."
        exit 1
    fi
    echo "Detected interface: $HOST_IFACE"
}

_capture_env() {
    local var="$1"
    local pid
    pid=$(pgrep -u "$REAL_USER" -x bash 2>/dev/null | head -1) || true
    if [ -n "${pid:-}" ]; then
        tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null | grep "^${var}=" | head -1 | cut -d= -f2- || true
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: root required. Run: sudo $0 $*"
        exit 1
    fi
}

setup() {
    _detect_iface
    echo "=== Setting up namespace $NS_NAME (via $HOST_IFACE) ==="
    cleanup_internal 2>/dev/null || true

    ip netns add "$NS_NAME"
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NS_NAME"
    ip addr add "${HOST_IP}/24" dev "$VETH_HOST"
    ip link set "$VETH_HOST" up
    ip netns exec "$NS_NAME" ip addr add "${NS_IP}/24" dev "$VETH_NS"
    ip netns exec "$NS_NAME" ip link set "$VETH_NS" up
    ip netns exec "$NS_NAME" ip link set lo up
    ip netns exec "$NS_NAME" ip route add default via "$HOST_IP"
    ip netns exec "$NS_NAME" bash -c "echo nameserver $DNS_SERVER > /etc/resolv.conf"

    ip netns exec "$NS_NAME" sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    ip netns exec "$NS_NAME" sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null

    ip rule add from "$SUBNET" lookup main priority "$IP_RULE_PRIO"

    nft add table inet bypass 2>/dev/null || true
    nft add chain inet bypass forward '{ type filter hook forward priority filter - 5; policy accept; }' 2>/dev/null || true
    nft flush chain inet bypass forward 2>/dev/null || true
    nft add rule inet bypass forward iifname "$VETH_HOST" accept
    nft add rule inet bypass forward iifname "$HOST_IFACE" oifname "$VETH_HOST" ct state established,related accept
    nft add chain inet bypass postrouting '{ type nat hook postrouting priority srcnat - 1; }' 2>/dev/null || true
    nft flush chain inet bypass postrouting 2>/dev/null || true
    nft add rule inet bypass postrouting ip saddr "$SUBNET" oifname "$HOST_IFACE" masquerade

    firewall-cmd --permanent --zone=trusted --add-interface="$VETH_HOST" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    echo "Setup complete."
}

cleanup_internal() {
    firewall-cmd --permanent --zone=trusted --remove-interface="$VETH_HOST" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    nft delete table inet bypass 2>/dev/null || true
    ip rule del from "$SUBNET" lookup main priority "$IP_RULE_PRIO" 2>/dev/null || true
    ip netns del "$NS_NAME" 2>/dev/null || true
    ip link del "$VETH_HOST" 2>/dev/null || true
}

cleanup() {
    echo "=== Removing namespace $NS_NAME ==="
    cleanup_internal
    echo "Cleanup complete."
}

run() {
    _detect_iface

    if ! ip netns list | grep -qw "$NS_NAME"; then
        echo "Namespace not found, running setup..."
        setup
    fi

    ip netns exec "$NS_NAME" /usr/bin/sleep infinity &
    HELPER_PID=$!
    sleep 0.5
    trap "kill $HELPER_PID 2>/dev/null" EXIT

    echo "=== Starting Bottles (bypassing Tailscale via $HOST_IFACE) ==="
    echo "Public IP: $(nsenter --target "$HELPER_PID" --net --mount curl -s --max-time 5 ifconfig.me 2>/dev/null || echo '?')"
    echo ""

    E_DBUS="$(_capture_env DBUS_SESSION_BUS_ADDRESS)"
    E_DISP="$(_capture_env DISPLAY)"
    E_WAY="$(_capture_env WAYLAND_DISPLAY)"
    E_XAUTH="$(_capture_env XAUTHORITY)"
    E_XDG_RT="$(_capture_env XDG_RUNTIME_DIR)"
    E_XDG_DATA="$(_capture_env XDG_DATA_DIRS)"
    E_SESSION="$(_capture_env XDG_SESSION_TYPE)"
    E_DESK="$(_capture_env XDG_CURRENT_DESKTOP)"
    E_HOME="$(_capture_env HOME)"
    E_GTK="$(_capture_env GTK_IM_MODULES)"
    UID_R=$(id -u "$REAL_USER")
    GID_R=$(id -g "$REAL_USER")

    WRAPPER=$(mktemp /tmp/bottles-ns-XXXXXX.sh)
    cat > "$WRAPPER" << WRAPPER_EOF
#!/bin/bash
export DBUS_SESSION_BUS_ADDRESS="$E_DBUS"
export DISPLAY="$E_DISP"
export WAYLAND_DISPLAY="$E_WAY"
export XAUTHORITY="$E_XAUTH"
export XDG_RUNTIME_DIR="$E_XDG_RT"
export XDG_DATA_DIRS="$E_XDG_DATA"
export XDG_SESSION_TYPE="$E_SESSION"
export XDG_CURRENT_DESKTOP="$E_DESK"
export HOME="$E_HOME"
export USER="$REAL_USER"
export LOGNAME="$REAL_USER"
export GTK_IM_MODULES="$E_GTK"
export PATH="$PATH"
export LANG="\${LANG:-en_US.UTF-8}"
export TERM="\${TERM:-xterm-256color}"
exec flatpak run --command=bottles-cli $FLATPAK_APP run -p $PROGRAM_NAME -b $BOTTLE_NAME "\$@"
WRAPPER_EOF
    chmod 755 "$WRAPPER"

    nsenter --target "$HELPER_PID" --net --mount \
      --setuid="$UID_R" --setgid="$GID_R" \
      /bin/bash "$WRAPPER" "$@"

    rm -f "$WRAPPER"
    kill "$HELPER_PID" 2>/dev/null || true
    trap - EXIT
}

check() {
    if ! ip netns list | grep -qw "$NS_NAME"; then
        echo "Namespace $NS_NAME: not active (run: sudo $0 --setup)"
        return
    fi
    echo "Namespace $NS_NAME: active"
    ip netns exec "$NS_NAME" curl -s --max-time 5 ifconfig.me 2>/dev/null && echo "" || echo "(unavailable)"
}

case "${1:-}" in
    --setup)    need_root "$@"; setup ;;
    --cleanup|--teardown) need_root "$@"; cleanup ;;
    --check)    need_root "$@"; check ;;
    *)          need_root "$@"; run "$@" ;;
esac
