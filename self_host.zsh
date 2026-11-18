#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="syncplay"
SESSION_NAME="${APP_NAME}-server"
DEFAULT_URL="http://${APP_NAME}.pinky.lilf.ir"
ROOT_DIR="${0:A:h}"
UPSTREAM_REPO="https://github.com/Syncplay/syncplay.git"
SRC_DIR="$ROOT_DIR/.runtime/syncplay"
VENV_DIR="$ROOT_DIR/.runtime/venv"
PUBLIC_DIR="$ROOT_DIR/public"
DATA_DIR="$ROOT_DIR/data"
MOTD_FILE="$DATA_DIR/motd.txt"
ROOMS_DB_FILE="$DATA_DIR/rooms.sqlite"
SALT_FILE="$DATA_DIR/salt"
CADDYFILE="${CADDYFILE:-$HOME/Caddyfile}"
SYNCPLAY_PORT="${SYNCPLAY_PORT:-8999}"
SYNCPLAY_URL="${2:-${SYNCPLAY_URL:-$DEFAULT_URL}}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Required local helper. Additional arguments are passed to `tmux new` after -s.
tmuxnew () {
	tmux kill-session -t "$1" &> /dev/null || true
	tmux new -d -s "$@"
}

usage() {
  cat <<USAGE
Usage: ./self_host.zsh [setup|redeploy|start|stop|dev-start|render-site] [url]

Environment:
  SYNCPLAY_URL       Public landing-page URL (default: $DEFAULT_URL)
  SYNCPLAY_PORT      Raw Syncplay TCP port (default: 8999)
  SYNCPLAY_PASSWORD  Optional Syncplay server password
  SYNCPLAY_SALT      Optional managed-room salt
  CADDYFILE          Caddyfile path (default: ~/Caddyfile)
USAGE
}

have() { command -v "$1" >/dev/null 2>&1 }

require_cmds() {
  local missing=()
  for cmd in git tmux "$PYTHON_BIN"; do
    have "$cmd" || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    print -u2 "Missing required command(s): ${missing[*]}"
    exit 1
  fi
}

host_from_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  print -- "${url%%/*}"
}

port_in_use() {
  local port="$1"
  if have ss; then
    ss -ltn "sport = :$port" | tail -n +2 | grep -q .
  elif have lsof; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    "$PYTHON_BIN" - <<PY
import socket, sys
s=socket.socket()
try:
    s.bind(('127.0.0.1', int('$port')))
except OSError:
    sys.exit(0)
s.close(); sys.exit(1)
PY
  fi
}

assert_port_free() {
  local port="$1"
  if port_in_use "$port"; then
    print -u2 "Port $port is already in use. Set SYNCPLAY_PORT to a free port or stop the conflicting service."
    if have ss; then ss -ltnp "sport = :$port" || true; fi
    exit 1
  fi
}

ensure_upstream() {
  mkdir -p "$ROOT_DIR/.runtime"
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin
    git -C "$SRC_DIR" checkout -f origin/master
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$UPSTREAM_REPO" "$SRC_DIR"
  fi
}

ensure_venv() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel
  "$VENV_DIR/bin/python" -m pip install -r "$SRC_DIR/requirements.txt"
}

write_runtime_files() {
  mkdir -p "$PUBLIC_DIR" "$DATA_DIR"
  [[ -f "$MOTD_FILE" ]] || cat > "$MOTD_FILE" <<MOTD
Welcome to this private Syncplay server.
MOTD
  if [[ -z "${SYNCPLAY_SALT-}" && ! -f "$SALT_FILE" ]]; then
    "$PYTHON_BIN" - <<PY > "$SALT_FILE"
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(32)))
PY
    chmod 600 "$SALT_FILE"
  fi
  render_site
}

render_site() {
  mkdir -p "${PUBLIC_DIR}"
  "${PYTHON_BIN}" - "${ROOT_DIR}/site/index.html" "${PUBLIC_DIR}/index.html" "$(host_from_url "${SYNCPLAY_URL}"):${SYNCPLAY_PORT}" <<'PYTHON'
import hashlib
import html
import os
import sys
import tempfile
from pathlib import Path

template, destination, address = sys.argv[1:]
icon = Path(destination).with_name("syncplayu.png")
icon_hash = hashlib.sha256(icon.read_bytes()).hexdigest()[:12]
page = Path(template).read_text().replace("@SERVER_ADDRESS@", html.escape(address, quote=True))
page = page.replace("@ICON_HASH@", icon_hash)
with tempfile.NamedTemporaryFile(mode="w", dir=Path(destination).parent, delete=False) as output:
    output.write(page)
os.chmod(output.name, 0o644)
os.replace(output.name, destination)
PYTHON
}

write_caddyfile() {
  mkdir -p "${CADDYFILE:h}"
  touch "$CADDYFILE"
  local begin="# BEGIN ${APP_NAME}-selfhost"
  local end="# END ${APP_NAME}-selfhost"
  local tmp="${CADDYFILE}.tmp.$$"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$CADDYFILE" > "$tmp"
  cat >> "$tmp" <<CADDY
$begin
$SYNCPLAY_URL {
	root * $PUBLIC_DIR
	file_server
}
$end
CADDY
  mv "$tmp" "$CADDYFILE"
  if have caddy; then
    caddy fmt --overwrite "$CADDYFILE" >/dev/null || true
    caddy reload --config "$CADDYFILE" >/dev/null || print -u2 "Caddyfile updated at $CADDYFILE. Reload Caddy manually if it is not managed by this user."
  else
    print -u2 "Caddy is not installed/in PATH. Caddyfile updated at $CADDYFILE."
  fi
}

tmux_env_args() {
  local var val
  for var in ALL_PROXY all_proxy http_proxy https_proxy HTTP_PROXY HTTPS_PROXY npm_config_proxy npm_config_https_proxy NO_PROXY no_proxy SYNCPLAY_PASSWORD SYNCPLAY_SALT; do
    if [[ -n "${(P)var-}" ]]; then
      val="${(P)var}"
      print -r -- "-e"
      print -r -- "$var=$val"
    fi
  done
}

stop() {
  tmux kill-session -t "$SESSION_NAME" &>/dev/null || true
}

start_server() {
  stop
  assert_port_free "$SYNCPLAY_PORT"
  mkdir -p "$DATA_DIR"
  local -a env_args
  env_args=( "${(@f)$(tmux_env_args)}" )
  local salt="${SYNCPLAY_SALT:-$(<"$SALT_FILE")}"
  local cmd="cd ${(q)SRC_DIR} && exec ${(q)VENV_DIR}/bin/python ${(q)SRC_DIR}/syncplayServer.py --port ${(q)SYNCPLAY_PORT} --salt ${(q)salt} --motd-file ${(q)MOTD_FILE} --rooms-db-file ${(q)ROOMS_DB_FILE} --stats-db-file ${(q)DATA_DIR}/stats.sqlite"
  tmuxnew "$SESSION_NAME" "${env_args[@]}" "$cmd"
  print "Started tmux session $SESSION_NAME on TCP port $SYNCPLAY_PORT."
}

setup() {
  stop
  require_cmds
  assert_port_free "$SYNCPLAY_PORT"
  ensure_upstream
  ensure_venv
  write_runtime_files
  write_caddyfile
  start_server
}

redeploy() {
  stop
  require_cmds
  [[ -d "$SRC_DIR/.git" ]] || ensure_upstream
  ensure_venv
  write_runtime_files
  write_caddyfile
  start_server
}

dev_start() {
  print -u2 "dev-start is not applicable for this project: Syncplay server has no hot-reload/dev server path here. Use ./self_host.zsh redeploy after changes."
  exit 64
}

cmd="${1:-}"
case "$cmd" in
  render-site) render_site ;;
  setup) setup ;;
  redeploy) redeploy ;;
  start) require_cmds; [[ -f "$SRC_DIR/syncplayServer.py" && -x "$VENV_DIR/bin/python" ]] || { print -u2 "Run setup first."; exit 1; }; write_runtime_files; start_server ;;
  stop) stop ;;
  dev-start) dev_start ;;
  -h|--help|help|"") usage ;;
  *) print -u2 "Unknown command: $cmd"; usage; exit 2 ;;
esac
