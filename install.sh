#!/usr/bin/env bash
# Installs the omarchy-ring background service; `omarchy plugin add` only
# copies the widget. Safe to re-run: keeps your settings and login.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
share="$HOME/.local/share/omarchy-ring"
config="$HOME/.config/omarchy-ring"
state="$HOME/.local/state/omarchy-ring"
unit_dir="$HOME/.config/systemd/user"
bin_dir="$HOME/.local/bin"
plugin_id="nnathan.ring"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'omarchy-ring: %s\n' "$*" >&2; exit 1; }

# ring-client-api supports Node 20, 22 and 24 only.
node_ok() { [[ -x $1 ]] && [[ $("$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null) =~ ^(20|22|24)$ ]]; }

node_bin=""
if node_ok "$(command -v node || true)"; then
  node_bin="$(command -v node)"
elif command -v mise >/dev/null && node_ok "$(mise where node@24 2>/dev/null)/bin/node"; then
  node_bin="$(mise where node@24)/bin/node"
fi
[[ -n $node_bin ]] || die "needs Node 20, 22 or 24 (ring-client-api doesn't support others yet).
  With mise:  mise install node@24   then run this again."
node_bin="$(readlink -f "$node_bin")"
npm_bin="$(dirname "$node_bin")/npm"
[[ -x $npm_bin ]] || npm_bin="$(command -v npm || true)"
[[ -n $npm_bin ]] || die "npm not found next to $node_bin"
node_root="$(dirname "$(dirname "$node_bin")")"

for cmd in ffmpeg systemd-run omarchy-shell; do
  command -v "$cmd" >/dev/null || die "missing $cmd"
done
command -v pw-play >/dev/null || command -v mpv >/dev/null || echo "note: no pw-play or mpv, so the doorbell will be silent"

say "Using Node $("$node_bin" --version) at $node_bin"

mkdir -p "$share" "$state" "$unit_dir" "$bin_dir"
mkdir -p -m 700 "$config"
mkdir -p "$config/sounds"

install -m 644 "$here/service/omarchy-ring.mjs" "$here/service/notify.mjs" "$here/service/login.mjs" \
  "$here/service/package.json" "$here/service/package-lock.json" "$here/service/.npmrc" "$share/"

say "Installing ring-client-api (pinned, install scripts disabled)…"
# Exact versions from the lockfile, no package install scripts.
(cd "$share" && "$npm_bin" ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error)

[[ -e $config/sounds/ding-dong.ogg ]] || install -m 644 "$here/service/sounds/ding-dong.ogg" "$config/sounds/"

if [[ ! -e $config/config.json ]]; then
  cat > "$config/config.json" <<'JSON'
{
  "cameras": {},
  "keepDays": 7,
  "maxEvents": 200
}
JSON
  chmod 600 "$config/config.json"
fi

cat > "$bin_dir/omarchy-ring-login" <<EOF
#!/usr/bin/env bash
exec "$node_bin" "$share/login.mjs" "\$@"
EOF
chmod 755 "$bin_dir/omarchy-ring-login"

sed -e "s|@NODE@|$node_bin|" -e "s|@NODE_ROOT@|$node_root|" \
  "$here/service/omarchy-ring.service.in" > "$unit_dir/omarchy-ring.service"

systemctl --user daemon-reload
systemctl --user enable omarchy-ring.service >/dev/null
systemctl --user restart omarchy-ring.service
say "Service started."

if [[ -d $HOME/.config/omarchy/plugins/$plugin_id ]] && ! grep -q "\"$plugin_id\"" "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
  omarchy plugin enable "$plugin_id" >/dev/null 2>&1 && say "Widget added to the bar."
fi

cat <<EOF

Next: log in to Ring (email, password, then the 2FA code):

  omarchy-ring-login

Use the account that owns the cameras. The token is saved to
$config/refresh-token, readable only by you.
EOF
