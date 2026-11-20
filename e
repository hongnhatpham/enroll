#!/usr/bin/env bash
set -euo pipefail

die() { printf 'enroll: %s\n' "$*" >&2; exit 1; }
peer=${1:-}
port=${2:-8722}
[[ $peer =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#peer} -le 63 ]] || die 'usage: bash -s PEER [PORT], where PEER is the fleet machine that started this enrollment.'
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || die 'PORT must be 1024-65535.'
[[ $(id -u) -ne 0 ]] || die 'Run as your normal account, not root.'
[[ -r /dev/tty ]] || die 'Run this in a terminal.'
command -v python3 >/dev/null 2>&1 || die 'Install python3, then run the same line again.'
state=${XDG_STATE_HOME:-$HOME/.local/state}/agent-setup
mkdir -p -- "$state/kit"
chmod 700 -- "$state"

if ! command -v tailscale >/dev/null 2>&1; then
  echo 'Your password is needed once, to install Tailscale and set up this machine.'
  if command -v pacman >/dev/null 2>&1; then
    if [[ ! -s /var/lib/pacman/sync/core.db ]]; then
      sudo pacman -Sy </dev/tty
      : > "$state/system-update-pending"
    fi
    sudo pacman -S --needed --noconfirm tailscale </dev/tty
  else
    command -v curl >/dev/null 2>&1 || die 'Install curl, then run the same line again.'
    curl -fsSL https://tailscale.com/install.sh | sh </dev/tty
  fi
fi
systemctl is-active --quiet tailscaled 2>/dev/null || sudo systemctl enable --now tailscaled </dev/tty
if ! tailscale ip -4 >/dev/null 2>&1; then
  echo 'Approval 1 of 3, Tailscale: scan the code with your phone, or open the link, and approve this machine.'
  sudo tailscale up --qr </dev/tty
fi

peer_ip=$(tailscale ip -4 "$peer" 2>/dev/null | head -n 1) || true
[[ -n ${peer_ip:-} ]] || die "$peer is not a device on this tailnet."
python3 - "$peer_ip" <<'PY' || die "$peer is not one of your own untagged Tailscale devices."
import json, subprocess, sys
who = json.loads(subprocess.check_output(["tailscale", "whois", "--json", sys.argv[1]]))
me = json.loads(subprocess.check_output(["tailscale", "status", "--json", "--peers=false"]))["Self"]
sys.exit(0 if not who["Node"].get("Tags") and who["UserProfile"]["ID"] == me["UserID"] else 1)
PY

address=$peer_ip:$port
for part in setup.sh plan; do
  if ! curl -fsS -m 30 "http://$address/$part" -o "$state/kit/$part.new"; then
    rm -f -- "$state/kit/$part.new"
    [[ -s $state/kit/$part ]] || die "$peer is not serving an enrollment for this machine. Start one there: python tools/agent.py enroll start ID"
    echo "Using the kit saved earlier; $peer did not answer."
  else
    mv -f -- "$state/kit/$part.new" "$state/kit/$part"
  fi
done

args=()
while IFS= read -r line; do
  [[ $line =~ ^(machine-id|mode|peer-id|peer-public-key|checkout-path|skip)=([A-Za-z0-9\ @:+/=._,~-]+)$ ]] || die 'The enrollment plan has an unexpected line.'
  args+=("--${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
done < "$state/kit/plan"
ENROLL_PEER_ADDRESS=$address exec bash "$state/kit/setup.sh" "${args[@]}" </dev/tty
