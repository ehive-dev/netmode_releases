#!/usr/bin/env bash
set -euo pipefail
umask 022

APP_DISPLAY="netmode"
PKG_NAME="netmode"
SERVICE_NAME="netmode"
REPO="${REPO:-ehive-dev/netmode_releases}"
TAG="${TAG:-}"
CHANNEL="${CHANNEL:-stable}"
ASSET_PREFIXES="netmode"
ARCH_ORDER="all arm64 amd64"
HEALTH_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    -h|--help)
      echo "Usage: sudo $0 [--tag vX.Y.Z] [--repo owner/repo] [--stable|--pre]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

need_tools(){
  command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }
  command -v dpkg-deb >/dev/null || { apt-get update -y; apt-get install -y dpkg; }
  dpkg-query -W -f='${Status}\n' ca-certificates 2>/dev/null | grep -q 'install ok installed' || { apt-get update -y; apt-get install -y ca-certificates; }
}

installed_version(){
  dpkg-query -W -f='${Version}\n' "$PKG_NAME" 2>/dev/null || true
}

resolve_latest_tag(){
  local effective
  effective="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" || true)"
  effective="${effective%%[?#]*}"
  if [[ "$effective" == */tag/* ]]; then
    printf '%s\n' "${effective##*/tag/}"
    return 0
  fi
  return 1
}

api(){
  local url="$1"
  if command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1; then
    gh api "${url#https://api.github.com/}"
    return
  fi
  local hdr=(-H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN:-}}")
  fi
  curl -fsSL "${hdr[@]}" "$url"
}

resolve_tag(){
  if [[ -n "$TAG" ]]; then
    printf '%s\n' "$TAG"
    return
  fi
  if [[ "$CHANNEL" == "stable" ]]; then
    resolve_latest_tag && return
  fi
  command -v jq >/dev/null || { apt-get update -y; apt-get install -y jq; }
  api "https://api.github.com/repos/${REPO}/releases?per_page=50" |
    jq -r --arg ch "$CHANNEL" '
      [ .[] | select(.draft==false) ] as $r
      | if $ch=="pre"
        then (($r | map(select(.prerelease==true)) | .[0]) // ($r | map(select(.prerelease==false)) | .[0]))
        else (($r | map(select(.prerelease==false)) | .[0]) // ($r | map(select(.prerelease==true)) | .[0]))
        end
      | .tag_name // empty
    '
}

asset_exists(){
  curl -fsIL --retry 2 --retry-delay 1 "$1" >/dev/null 2>&1
}

resolve_deb_url(){
  local tag="$1"
  local ver="${tag#v}"
  local prefix arch url name found
  local candidates=()
  for prefix in $ASSET_PREFIXES; do
    for arch in $ARCH_ORDER; do
      name="${prefix}_${ver}_${arch}.deb"
      candidates+=("$name")
      url="https://github.com/${REPO}/releases/download/${tag}/${name}"
      if asset_exists "$url"; then
        printf '%s\n' "$url"
        return 0
      fi
    done
  done

  command -v jq >/dev/null || { apt-get update -y; apt-get install -y jq; }
  local json
  json="$(api "https://api.github.com/repos/${REPO}/releases/tags/${tag}" 2>/dev/null || true)"
  [[ -n "$json" ]] || return 0
  for name in "${candidates[@]}"; do
    found="$(printf '%s' "$json" | jq -r --arg name "$name" '.assets[]? | select(.name == $name) | .browser_download_url' | head -n1)"
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
}

stop_service(){
  [[ -n "$SERVICE_NAME" ]] || return 0
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
}

start_service(){
  [[ -n "$SERVICE_NAME" ]] || return 0
  systemctl daemon-reload || true
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" || true
}

wait_service(){
  [[ -n "$SERVICE_NAME" ]] || return 0
  for _ in {1..30}; do
    systemctl is-active --quiet "$SERVICE_NAME" && return 0
    sleep 1
  done
  return 1
}

wait_health(){
  [[ -n "$HEALTH_URL" ]] || return 0
  for _ in {1..30}; do
    curl -fsS "$HEALTH_URL" >/dev/null && return 0
    sleep 1
  done
  return 1
}

need_root
need_tools

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then
  info "Installiert: ${APP_DISPLAY} ${OLD_VER}"
else
  info "Keine bestehende ${APP_DISPLAY}-Installation gefunden."
fi

info "Ermittle Release aus ${REPO} (${CHANNEL}) ..."
TAG="$(resolve_tag | head -n1)"
if [[ -z "$TAG" ]]; then
  err "Keine passende Release gefunden (Repo: ${REPO})."
  exit 1
fi

VER_CLEAN="${TAG#v}"
DEB_URL="$(resolve_deb_url "$TAG" | head -n1)"
if [[ -z "$DEB_URL" ]]; then
  err "Kein passendes .deb Asset in Release ${TAG} gefunden."
  err "Repo: ${REPO}"
  err "Prefixe: ${ASSET_PREFIXES}; Arch: ${ARCH_ORDER}"
  exit 1
fi

TMPDIR="$(mktemp -d -t "${PKG_NAME}-install.XXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${PKG_NAME}_${VER_CLEAN}.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 5 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"
dpkg-deb --info "$DEB_FILE" >/dev/null || { err "Ungültiges .deb Asset."; exit 1; }

stop_service
info "Installiere Paket ..."
if ! dpkg -i "$DEB_FILE"; then
  warn "dpkg meldet Abhängigkeiten, versuche apt-get -f install ..."
  apt-get update -y
  apt-get -f install -y
  dpkg -i "$DEB_FILE"
fi

start_service
if ! wait_service; then
  err "Service ist nicht active: ${SERVICE_NAME}"
  journalctl -u "$SERVICE_NAME" -n 120 --no-pager -o cat || true
  exit 1
fi
if ! wait_health; then
  err "Health-Check fehlgeschlagen: ${HEALTH_URL}"
  journalctl -u "$SERVICE_NAME" -n 120 --no-pager -o cat || true
  exit 1
fi

NEW_VER="$(installed_version || echo "$VER_CLEAN")"
ok "Fertig: ${APP_DISPLAY} ${OLD_VER:+${OLD_VER} → }${NEW_VER}"
