#!/usr/bin/env bash
set -euo pipefail
umask 022

# WattRadar Installer/Updater (DietPi / arm64)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ehive-dev/wattRadar-releases/main/install.sh | sudo bash -s -- [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]
#   sudo bash install.sh --pre | --stable | --tag vX.Y.Z | --repo owner/repo

# Feste Bezeichnungen (Case-sensitiv)
APP_NAME="wattRadar"           # exakt: wattRadar
UNIT="${APP_NAME}.service"     # wattRadar.service
UNIT_BASE="${APP_NAME}"        # Verzeichnisnamen für State/Logs

# Optional:
#   REPO=ehive-dev/wattRadar-releases
#   DPKG_PKG=wattRadar
#   PORT=3011
#   HEALTH_PATH=/healthz

REPO="${REPO:-ehive-dev/wattRadar-releases}"
CHANNEL="stable"               # stable | pre
TAG="${TAG:-}"
ARCH_REQ="arm64"
DPKG_PKG="${DPKG_PKG:-$APP_NAME}"

# ---------- CLI-Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------- Helpers ----------
info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Bitte als root ausführen (sudo)."; exit 1; fi
}
need_tools(){
  command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }
  command -v jq   >/dev/null || { apt-get update -y; apt-get install -y jq; }
  command -v ss   >/dev/null 2>&1 || true
  command -v systemctl >/dev/null || { err "systemd/systemctl erforderlich."; exit 1; }
}

api(){
  local url="$1"
  local hdr=(-H "Accept: application/vnd.github+json")
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -fsSL "${hdr[@]}" "$url"
}

trim_one_line(){ tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]\+$//'; }

get_release_json(){
  if [[ -n "$TAG" ]]; then
    api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
  else
    api "https://api.github.com/repos/${REPO}/releases?per_page=25" \
    | jq -c 'if "'"${CHANNEL}"'"=="pre" then ([ .[]|select(.draft==false and .prerelease==true) ]|.[0]) else ([ .[]|select(.draft==false and .prerelease==false) ]|.[0]) end'
  fi
}

pick_deb_from_release(){
  jq -r --arg arch "$ARCH_REQ" --arg app "$APP_NAME" '
    .assets // [] | map(select(.name | test("^" + $app + "_.*_" + $arch + "\\.deb$"))) | .[0].browser_download_url // empty
  '
}

installed_version(){ dpkg-query -W -f='${Version}\n' "$DPKG_PKG" 2>/dev/null || true; }

get_port(){
  local p="${PORT:-3011}"
  if [[ -r "/etc/default/${APP_NAME}" ]]; then . "/etc/default/${APP_NAME}" || true; p="${PORT:-$p}"; fi
  echo "$p"
}
get_health_path(){
  local hp="${HEALTH_PATH:-/healthz}"
  if [[ -r "/etc/default/${APP_NAME}" ]]; then . "/etc/default/${APP_NAME}" || true; hp="${HEALTH_PATH:-$hp}"; fi
  echo "$hp"
}

wait_port(){
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 0
  for _ in {1..60}; do ss -ltn 2>/dev/null | grep -q ":${port} " && return 0; sleep 0.5; done
  return 1
}
wait_health(){
  local url="$1"
  for _ in {1..30}; do curl -fsS "$url" >/dev/null && return 0; sleep 1; done
  return 1
}

detect_exec(){
  # Bevorzugt das gepackte Binary
  if [[ -x "/usr/local/bin/${APP_NAME}" ]]; then
    echo "/usr/local/bin/${APP_NAME}"
  elif command -v "${APP_NAME}" >/dev/null 2>&1; then
    command -v "${APP_NAME}"
  elif command -v wattradar >/dev/null 2>&1; then
    command -v wattradar
  elif command -v wattRadar >/dev/null 2>&1; then
    command -v wattRadar
  elif [[ -x "/opt/${APP_NAME}/bin/${APP_NAME}" ]]; then
    echo "/opt/${APP_NAME}/bin/${APP_NAME}"
  elif [[ -f "/opt/${APP_NAME}/app.js" ]]; then
    echo "/usr/bin/node /opt/${APP_NAME}/app.js"
  else
    echo "/usr/bin/${APP_NAME}"
  fi
}

# ---------- Start ----------
need_root
need_tools

ARCH_SYS="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [[ "$ARCH_SYS" != "$ARCH_REQ" ]]; then warn "Systemarchitektur '$ARCH_SYS', Release ist für '$ARCH_REQ'."; exit 1; fi

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then info "Installiert: ${DPKG_PKG} ${OLD_VER}"; else info "Keine bestehende ${DPKG_PKG}-Installation gefunden."; fi

info "Ermittle Release aus ${REPO} (${CHANNEL}${TAG:+, tag=$TAG}) ..."
RELEASE_JSON="$(get_release_json)"
if [[ -z "$RELEASE_JSON" || "$RELEASE_JSON" == "null" ]]; then err "Keine passende Release gefunden."; exit 1; fi

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
[[ -z "$TAG" ]] && TAG="$TAG_NAME"
VER_CLEAN="${TAG#v}"

DEB_URL_RAW="$(printf '%s' "$RELEASE_JSON" | pick_deb_from_release || true)"
DEB_URL="$(printf '%s' "$DEB_URL_RAW" | trim_one_line)"
[[ -z "$DEB_URL" ]] && { err "Kein .deb Asset (${ARCH_REQ}) in Release ${TAG} gefunden."; exit 1; }

TMPDIR="$(mktemp -d -t wattradar-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${APP_NAME}_${VER_CLEAN}_${ARCH_REQ}.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"
dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || { err "Ungültiges .deb"; exit 1; }

# Service anhalten, egal ob aktiv
systemctl stop "$UNIT" || true

info "Installiere Paket ..."
set +e
dpkg -i "$DEB_FILE"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  warn "dpkg -i scheiterte — versuche apt --fix-broken"
  apt-get update -y
  apt-get -f install -y
  dpkg -i "$DEB_FILE"
fi
ok "Installiert: ${DPKG_PKG} ${VER_CLEAN}"

### --- systemd: Service + Verzeichnisse ---
# /etc/default nur anlegen, wenn nicht vorhanden
if [[ ! -f /etc/default/${APP_NAME} ]]; then
  install -D -m 644 /dev/null /etc/default/${APP_NAME}
  {
    echo "PORT=${PORT:-3011}"
    echo "# INFLUX_URL=http://localhost:8086"
    echo "# UPDATE_LOG=/var/log/${UNIT_BASE}/update.log"
    echo "# UPDATE_LOCK=/var/lib/${UNIT_BASE}/update.lock"
    echo "HEALTH_PATH=${HEALTH_PATH:-/healthz}"
  } >>/etc/default/${APP_NAME}
fi

# Unit-Datei bereitstellen, falls nicht vorhanden
UNIT_PATH="/etc/systemd/system/${UNIT}"
if ! systemctl list-unit-files | awk '{print $1}' | grep -qx "${UNIT}"; then
  EXEC_BIN="$(detect_exec)"
  install -D -m 644 /dev/null "$UNIT_PATH"
  cat >"$UNIT_PATH" <<UNITFILE
[Unit]
Description=${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=-/etc/default/${APP_NAME}
ExecStart=${EXEC_BIN}
Restart=always
RestartSec=3s
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
KillMode=process
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
UNITFILE
fi

# Drop-in sicherstellen (State/Logs auch wenn Unit aus Paket kommt)
install -d -m 755 "/etc/systemd/system/${UNIT}.d"
cat >"/etc/systemd/system/${UNIT}.d/10-paths.conf" <<UNITDROP
[Service]
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
UNITDROP

# Aktivieren/Starten
systemctl daemon-reload
systemctl enable --now "${UNIT}" || true
systemctl restart "${UNIT}" || true

PORT="$(get_port)"
H_PATH="$(get_health_path)"
URL="http://127.0.0.1:${PORT}${H_PATH}"

info "Warte auf Port :${PORT} ..."
wait_port "$PORT" || { err "Port ${PORT} lauscht nicht."; journalctl -u "${UNIT}" -n 200 --no-pager -o cat || true; exit 1; }

info "Prüfe Health ${URL} ..."
wait_health "$URL" || { err "Health-Check fehlgeschlagen."; journalctl -u "${UNIT}" -n 200 --no-pager -o cat || true; exit 1; }

NEW_VER="$(installed_version || echo "$VER_CLEAN")"
ok "Fertig: ${APP_NAME} ${OLD_VER:+${OLD_VER} → }${NEW_VER} (healthy @ ${URL})"
