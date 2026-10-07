#!/usr/bin/env bash
# Removes the omarchy-ring service. The widget is removed with
# `omarchy plugin remove nnathan.ring`.
set -euo pipefail

config="$HOME/.config/omarchy-ring"
state="$HOME/.local/state/omarchy-ring"

systemctl --user disable --now omarchy-ring.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/omarchy-ring.service"
systemctl --user daemon-reload
rm -rf "$HOME/.local/share/omarchy-ring"
rm -f "$HOME/.local/bin/omarchy-ring-login"
echo "Service removed."

read -r -p "Also delete your Ring login, settings, sounds and saved events? [y/N] " answer
if [[ $answer =~ ^[Yy]$ ]]; then
  rm -rf "$config" "$state"
  echo "Deleted $config and $state."
else
  echo "Kept $config and $state."
fi

cat <<'EOF'

Ring still lists this computer as "omarchy-ring" until you remove it:
ring.com → Control Center → Authorized Client Devices.
EOF
