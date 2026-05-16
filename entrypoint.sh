#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[wireguard-client] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

read_secret() {
  local name="$1"
  local file_name="${name}_FILE"
  local value="${!name:-}"
  local file_value="${!file_name:-}"

  if [[ -n "${value}" && -n "${file_value}" ]]; then
    die "Set either ${name} or ${file_name}, not both"
  fi

  if [[ -n "${file_value}" ]]; then
    [[ -r "${file_value}" ]] || die "${file_name} points to an unreadable file: ${file_value}"
    value="$(< "${file_value}")"
  fi

  printf '%s' "${value}"
}

require_value() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" ]] || die "Missing ${name}"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

emit_hook_lines() {
  local hook_name="$1"
  local raw_value="$2"
  local line

  raw_value="${raw_value//;/$'\n'}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim "${line}")"
    [[ -n "${line}" ]] && printf '%s = %s\n' "${hook_name}" "${line}"
  done <<< "${raw_value}"

  return 0
}

append_optional() {
  local key="$1"
  local value="$2"

  if [[ -n "${value}" ]]; then
    printf '%s = %s\n' "${key}" "${value}"
  fi

  return 0
}

render_config() {
  local output_file="$1"

  {
    printf '[Interface]\n'
    printf 'Address = %s\n' "${WG_ADDRESS}"
    printf 'PrivateKey = %s\n' "${WG_PRIVATE_KEY}"
    append_optional "ListenPort" "${WG_LISTEN_PORT:-}"
    append_optional "DNS" "${WG_DNS:-}"
    append_optional "MTU" "${WG_MTU:-}"
    append_optional "Table" "${WG_TABLE:-}"
    append_optional "FwMark" "${WG_FWMARK:-}"
    emit_hook_lines "PreUp" "${PRE_UP:-}"
    emit_hook_lines "PostUp" "${POST_UP:-}"
    emit_hook_lines "PreDown" "${PRE_DOWN:-}"
    emit_hook_lines "PostDown" "${POST_DOWN:-}"
    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "${PEER_PUBLIC_KEY}"
    append_optional "PresharedKey" "${PEER_PRESHARED_KEY}"
    printf 'Endpoint = %s\n' "${PEER_ENDPOINT}"
    printf 'AllowedIPs = %s\n' "${PEER_ALLOWED_IPS}"
    append_optional "PersistentKeepalive" "${PEER_PERSISTENT_KEEPALIVE:-25}"
  } > "${output_file}"

  chmod 600 "${output_file}"
}

next_config_path() {
  local timestamp
  local path
  local suffix

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  path="${CONFIG_HISTORY_DIR}/${WG_IF}-${timestamp}.conf"
  suffix=1

  while [[ -e "${path}" || -L "${path}" ]]; do
    path="${CONFIG_HISTORY_DIR}/${WG_IF}-${timestamp}-${suffix}.conf"
    ((suffix += 1))
  done

  printf '%s' "${path}"
}

point_latest_link() {
  local config_path="$1"
  local link_target

  link_target="$(basename "${config_path}")"
  ln -sfn "${link_target}" "${LATEST_CONFIG_LINK}"
  [[ -L "${LATEST_CONFIG_LINK}" ]] || die "Failed to create symlink ${LATEST_CONFIG_LINK}"
}

copy_runtime_config() {
  local config_path="$1"

  cp "${config_path}" "${RUNTIME_CONFIG}"
  chmod 600 "${RUNTIME_CONFIG}"
}

persist_rendered_config() {
  local rendered_config="$1"
  local existing_config=""
  local archived_config
  local new_config

  if [[ -L "${LATEST_CONFIG_LINK}" ]]; then
    existing_config="$(readlink -f "${LATEST_CONFIG_LINK}" || true)"
    if [[ -n "${existing_config}" && -f "${existing_config}" ]]; then
      if cmp -s "${rendered_config}" "${existing_config}"; then
        log "Generated config matches ${existing_config}; keeping existing history"
        copy_runtime_config "${existing_config}"
        return 0
      fi

      log "Generated config changed from ${existing_config}; keeping both versions"
    else
      log "Replacing broken config symlink ${LATEST_CONFIG_LINK}"
    fi
  elif [[ -e "${LATEST_CONFIG_LINK}" ]]; then
    [[ -f "${LATEST_CONFIG_LINK}" ]] || die "${LATEST_CONFIG_LINK} exists but is not a file"

    if cmp -s "${rendered_config}" "${LATEST_CONFIG_LINK}"; then
      existing_config="$(next_config_path)"
      mv "${LATEST_CONFIG_LINK}" "${existing_config}"
      chmod 600 "${existing_config}"
      point_latest_link "${existing_config}"
      log "Moved existing unchanged config to ${existing_config}"
      copy_runtime_config "${existing_config}"
      return 0
    fi

    archived_config="$(next_config_path)"
    mv "${LATEST_CONFIG_LINK}" "${archived_config}"
    chmod 600 "${archived_config}"
    log "Archived changed existing config as ${archived_config}"
  fi

  new_config="$(next_config_path)"
  cp "${rendered_config}" "${new_config}"
  chmod 600 "${new_config}"
  point_latest_link "${new_config}"
  copy_runtime_config "${new_config}"
  log "Created ${new_config}; ${LATEST_CONFIG_LINK} points to it"
}

WG_IF="${WG_IF:-wg0}"
[[ "${WG_IF}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "WG_IF must contain only letters, numbers, '.', '_', and '-'"

CONFIG_DIR="${CONFIG_DIR:-/etc/wireguard}"
RUNTIME_CONFIG="${CONFIG_DIR}/${WG_IF}.conf"
CONFIG_HISTORY_DIR="${CONFIG_HISTORY_DIR:-/config}"
LATEST_CONFIG_LINK="${CONFIG_HISTORY_DIR}/${WG_IF}.conf"

WG_PRIVATE_KEY="$(read_secret WG_PRIVATE_KEY)"
PEER_PUBLIC_KEY="$(read_secret PEER_PUBLIC_KEY)"
PEER_PRESHARED_KEY="$(read_secret PEER_PRESHARED_KEY)"

mkdir -p "${CONFIG_DIR}" "${CONFIG_HISTORY_DIR}"
chmod 700 "${CONFIG_DIR}" "${CONFIG_HISTORY_DIR}"

WG_ADDRESS="${WG_ADDRESS:-}"
PEER_ENDPOINT="${PEER_ENDPOINT:-}"
PEER_ALLOWED_IPS="${PEER_ALLOWED_IPS:-}"

require_value WG_ADDRESS "${WG_ADDRESS}"
require_value WG_PRIVATE_KEY "${WG_PRIVATE_KEY}"
require_value PEER_PUBLIC_KEY "${PEER_PUBLIC_KEY}"
require_value PEER_ENDPOINT "${PEER_ENDPOINT}"
require_value PEER_ALLOWED_IPS "${PEER_ALLOWED_IPS}"

TMP_CONFIG="$(mktemp)"
trap '[[ -z "${TMP_CONFIG:-}" ]] || rm -f "${TMP_CONFIG}"' EXIT

log "Rendering WireGuard config from environment variables"
render_config "${TMP_CONFIG}"
persist_rendered_config "${TMP_CONFIG}"

rm -f "${TMP_CONFIG}"
TMP_CONFIG=""

cleanup() {
  local exit_code=$?

  trap - EXIT INT TERM
  log "Stopping ${WG_IF}"
  wg-quick down "${WG_IF}" > /dev/null 2>&1 || true
  exit "${exit_code}"
}

trap cleanup EXIT INT TERM

if ip link show "${WG_IF}" > /dev/null 2>&1; then
  if [[ "${WG_REPLACE_EXISTING:-false}" == "true" ]]; then
    log "Interface ${WG_IF} already exists; attempting cleanup before startup"
    wg-quick down "${WG_IF}" > /dev/null 2>&1 || ip link delete "${WG_IF}" > /dev/null 2>&1 || true
  else
    die "Interface ${WG_IF} already exists. Stop the existing owner, choose another WG_IF, or set WG_REPLACE_EXISTING=true."
  fi
fi

log "Starting ${WG_IF}"
wg-quick up "${WG_IF}"

RESOLVE_INTERVAL="${RESOLVE_INTERVAL:-0}"
if [[ "${RESOLVE_INTERVAL}" != "0" ]]; then
  [[ "${RESOLVE_INTERVAL}" =~ ^[0-9]+$ ]] || die "RESOLVE_INTERVAL must be 0 or a positive integer"
  [[ "${RESOLVE_INTERVAL}" -gt 0 ]] || die "RESOLVE_INTERVAL must be 0 or a positive integer"
  require_value PEER_PUBLIC_KEY "${PEER_PUBLIC_KEY}"
  require_value PEER_ENDPOINT "${PEER_ENDPOINT:-}"

  log "Refreshing peer endpoint DNS every ${RESOLVE_INTERVAL} seconds"
  while true; do
    sleep "${RESOLVE_INTERVAL}"
    wg set "${WG_IF}" peer "${PEER_PUBLIC_KEY}" endpoint "${PEER_ENDPOINT}" || true
  done &
fi

log "WireGuard is up"
while true; do
  sleep 86400 &
  wait "$!"
done
