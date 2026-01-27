#!/usr/bin/env bash
set -euo pipefail
umask 022

# netmode Installer/Updater (Debian/Ubuntu)
# Usage:
#   sudo bash install.sh                 # neueste STABLE (fällt auf PRE zurück, wenn kein Stable)
#   sudo bash install.sh --pre           # neueste PRE-RELEASE (fällt auf Stable zurück, wenn kein Pre)
#   sudo bash install.sh --tag v0.1.1    # bestimmte Version
#   sudo bash install.sh --repo owner/repo
#
# Optional: export GITHUB_TOKEN=... (höhere API-Limits/private Repos)

APP_NAME="netmode"
REPO="${REPO:-ehive-dev/netmode-releases}"  # per --repo überschreibbar
CHANNEL="stable"    # stable | pre  (fallback jeweils auf das andere, falls leer)
TAG="${TAG:-}"      # vX.Y.Z (mit v)

# Architektur: netmode ist "all" (Python + systemd), daher keine Arch-Sperre
# ARCH_REQ="all"

# ---------- CLI-Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------- Helpers ----------
info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

need_tools(){
  command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }
  command -v jq   >/dev/null || { apt-get update -y; apt-get install -y jq; }
}

api(){
  local url="$1"
  local hdr=(-H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL "${hdr[@]}" "$url"
}

trim_one_line(){
  tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]\+$//'
}

# Holt JSON EINER Release. Mit Fallback: stable→pre bzw. pre→stable
get_release_json(){
  if [[ -n "$TAG" ]]; then
    api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
    return
  fi

  local releases
  releases="$(api "https://api.github.com/repos/${REPO}/releases?per_page=50")"
  printf '%s' "$releases" | jq -c --arg ch "$CHANNEL" '
    [ .[] | select(.draft==false) ] as $r
    | if $ch=="pre"
      then ( $r | map(select(.prerelease==true)) | .[0] ) // ( $r | map(select(.prerelease==false)) | .[0] )
      else ( $r | map(select(.prerelease==false)) | .[0] ) // ( $r | map(select(.prerelease==true)) | .[0] )
      end
  '
}

# Erwartet JSON EINER Release auf stdin, gibt EXAKT EINE .deb-URL zurück (oder leer)
pick_deb_from_release(){
  # netmode assets werden typischerweise als netmode_<ver>_all.deb gebaut
  jq -r '
    .assets // []
    | map(select(.name | test("^netmode_.*_all\\.deb$")))
    | .[0].browser_download_url // empty
  '
}

installed_version(){
  dpkg-query -W -f='${Version}\n' "$APP_NAME" 2>/dev/null || true
}

# ---------- Start ----------
need_root
need_tools

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then
  info "Installiert: ${APP_NAME} ${OLD_VER}"
else
  info "Keine bestehende ${APP_NAME}-Installation gefunden."
fi

info "Ermittle Release aus ${REPO} (${CHANNEL}${TAG:+, tag=$TAG}) ..."
RELEASE_JSON="$(get_release_json)"
if [[ -z "$RELEASE_JSON" || "$RELEASE_JSON" == "null" ]]; then
  err "Keine passende Release gefunden."
  exit 1
fi

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
[[ -z "$TAG" ]] && TAG="$TAG_NAME"
VER_CLEAN="${TAG#v}"

DEB_URL_RAW="$(printf '%s' "$RELEASE_JSON" | pick_deb_from_release || true)"
DEB_URL="$(printf '%s' "$DEB_URL_RAW" | trim_one_line)"

if [[ -z "$DEB_URL" ]]; then
  err "Kein .deb Asset (*_all.deb) in Release ${TAG} gefunden."
  exit 1
fi

TMPDIR="$(mktemp -d -t netmode-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${APP_NAME}_${VER_CLEAN}_all.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"

# Sanity
dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || { err "Ungültiges .deb"; exit 1; }

# Vorhandenen Service sauber stoppen (dpkg/postinst startet neu)
if systemctl list-units --type=service | grep -q "^${APP_NAME}\.service"; then
  systemctl stop "$APP_NAME" || true
fi

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
ok "Installiert: ${APP_NAME} ${VER_CLEAN}"

systemctl daemon-reload || true
systemctl enable "$APP_NAME" || true
systemctl restart "$APP_NAME" || true

if systemctl is-active --quiet "$APP_NAME"; then
  ok "Fertig: ${APP_NAME} ${OLD_VER:+${OLD_VER} → }${VER_CLEAN} (service active)"
else
  err "Service ist nicht active: ${APP_NAME}"
  journalctl -u "$APP_NAME" -n 200 --no-pager -o cat || true
  exit 1
fi
