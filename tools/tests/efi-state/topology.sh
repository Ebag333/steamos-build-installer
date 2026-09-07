#!/bin/bash
#
# tools/tests/efi-state/topology.sh
# Deterministic topology helper for EFI state application tests.
#
# Provides reproducible UUID/PARTUUID generation keyed by test ID and role,
# so that parallel tests never collide and every test gets the same identities
# on repeated runs.
#
# Usage:
#   source tools/tests/efi-state/topology.sh
#
# Functions:
#   generate_deterministic_uuid   - UUID from test ID + role
#   generate_deterministic_partuuid - PARTUUID from test ID + partition
#   _create_topology_json          - write topology.json with all identities
#   _parse_topology_json           - read topology.json and export env vars
#   _get_partition_uuid            - query UUID for a partition
#   _get_partition_partuuid        - query PARTUUID for a partition
#   _get_slot_device               - device path for a slot's partition
#
# Topologies:
#   single-slot (Build): rootfs-A, efi-A, var-A, esp
#   dual-slot  (A/B):    rootfs-A, efi-A, var-A,
#                         rootfs-B, efi-B, var-B, esp

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "topology.sh is a library — source it, do not run directly." >&2
  exit 1
fi

# ── Partition catalogue ────────────────────────────────────────────────────
# Canonical list of partitions for each topology.
_TOPOLOGY_SINGLE_SLOT_PARTITIONS=(rootfs-A efi-A var-A esp)
_TOPOLOGY_DUAL_SLOT_PARTITIONS=(rootfs-A efi-A var-A rootfs-B efi-B var-B esp)

# ── Namespace key ──────────────────────────────────────────────────────────
# All UUIDs are derived from HMAC-SHA256(test_id || role) to guarantee:
#   1. Determinism  — same (test_id, role) always yields the same UUID.
#   2. Namespacing — different test_ids never collide, even in parallel.
#
# The project has no external crypto dependency; we use sha256sum(1) which
# is available on every Linux host that runs these tests.
#
# generate_deterministic_uuid TEST_ID ROLE
#   Return a v4-formatted UUID (8-4-4-4-12 hex, variant 10xx).
generate_deterministic_uuid() {
  local test_id="${1:?generate_deterministic_uuid: missing TEST_ID}"
  local role="${2:?generate_deterministic_uuid: missing ROLE}"

  # Build a deterministic input string.
  local input="${test_id}::${role}"

  # Hash with SHA-256 — output is 64 hex chars.
  local hash
  hash="$(printf '%s' "$input" | sha256sum | cut -d' ' -f1)"

  # Extract 32 hex chars from the hash for the UUID body.
  local body="${hash:0:32}"

  # Inject v4 version nibble (4 at position 12) and variant bits (10 at
  # position 16) to conform to RFC 4122.
  local v4_body
  v4_body="${body:0:8}-${body:8:4}-4${body:13:3}-$(printf '%x' $(((16#${body:16:1} & 0x3) | 0x8)))${body:17:3}-${body:20:12}"

  printf '%s' "$v4_body"
}

# generate_deterministic_partuuid TEST_ID PARTITION
#   Return a PARTUUID in the GPT "UUID of the partition" style.
#   Format: 8-4-4-4-12 hex (no variant/version — raw digest).
generate_deterministic_partuuid() {
  local test_id="${1:?generate_deterministic_partuuid: missing TEST_ID}"
  local partition="${2:?generate_deterministic_partuuid: missing PARTITION}"

  local input="${test_id}::partuuid::${partition}"
  local hash
  hash="$(printf '%s' "$input" | sha256sum | cut -d' ' -f1)"

  # Use 32 hex chars from the hash, formatted as 8-4-4-4-12.
  local raw="${hash:0:32}"
  printf '%s' "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
}

# ── Topology JSON helpers ──────────────────────────────────────────────────
# _create_topology_json TEST_ID TOPOLOGY_TYPE OUTPUT_DIR
#
#   TOPOLOGY_TYPE is "single-slot" or "dual-slot".
#
#   Writes OUTPUT_DIR/topology.json with one entry per partition:
#     {
#       "test_id": "...",
#       "topology": "dual-slot",
#       "partitions": {
#         "rootfs-A": { "uuid": "...", "partuuid": "...", "device": "..." },
#         ...
#       }
#     }
#
#   Device paths follow the convention /dev/disk/by-partuuid/<partuuid>.
_create_topology_json() {
  local test_id="${1:?_create_topology_json: missing TEST_ID}"
  local topology_type="${2:?_create_topology_json: missing TOPOLOGY_TYPE}"
  local output_dir="${3:?_create_topology_json: missing OUTPUT_DIR}"

  local -a partitions
  case "$topology_type" in
    single-slot) partitions=("${_TOPOLOGY_SINGLE_SLOT_PARTITIONS[@]}") ;;
    dual-slot) partitions=("${_TOPOLOGY_DUAL_SLOT_PARTITIONS[@]}") ;;
    *)
      echo "_create_topology_json: unknown topology type: $topology_type" >&2
      return 1
      ;;
  esac

  mkdir -p "$output_dir"

  local out_file="$output_dir/topology.json"

  # ── Manual JSON assembly (no jq dependency) ──────────────────────────────
  printf '{\n  "test_id": "%s",\n  "topology": "%s",\n  "partitions": {\n' \
    "$test_id" "$topology_type" >"$out_file"

  local first=1
  for part in "${partitions[@]}"; do
    local uuid partuuid device
    uuid="$(generate_deterministic_uuid "$test_id" "$part")"
    partuuid="$(generate_deterministic_partuuid "$test_id" "$part")"
    device="/dev/disk/by-partuuid/$partuuid"

    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      printf ',\n' >>"$out_file"
    fi

    printf '    "%s": {\n      "uuid": "%s",\n      "partuuid": "%s",\n      "device": "%s"\n    }' \
      "$part" "$uuid" "$partuuid" "$device" >>"$out_file"
  done

  printf '\n  }\n}\n' >>"$out_file"

  printf '%s' "$out_file"
}

# ── Topology JSON parsing ──────────────────────────────────────────────────
# _parse_topology_json TOPOLOGY_FILE
#
#   Read a topology.json file and export shell variables:
#     TOPOLOGY_TEST_ID          — the test ID
#     TOPOLOGY_TYPE             — "single-slot" or "dual-slot"
#     TOPOLOGY_PARTITIONS       — space-separated list of partition names
#     TOPOLOGY_<PART>_UUID      — UUID for each partition
#     TOPOLOGY_<PART>_PARTUUID  — PARTUUID for each partition
#     TOPOLOGY_<PART>_DEVICE    — device path for each partition
#
#   Partition names are upper-cased and hadhyphens converted to underscores
#   for shell variable safety (e.g. rootfs-A → rootfs_A).
#
#   Returns 0 on success, 1 on parse failure.
_parse_topology_json() {
  local toppo_file="${1:?_parse_topology_json: missing TOPOLOGY_FILE}"

  if [[ ! -f "$toppo_file" ]]; then
    echo "_parse_topology_json: file not found: $toppo_file" >&2
    return 1
  fi

  local content
  content="$(cat "$toppo_file")"

  # Extract test_id and topology type using grep -P (no jq).
  TOPOLOGY_TEST_ID="$(printf '%s' "$content" | grep -oP '"test_id"\s*:\s*"\K[^"]*')"
  TOPOLOGY_TYPE="$(printf '%s' "$content" | grep -oP '"topology"\s*:\s*"\K[^"]*')"

  if [[ -z "$TOPOLOGY_TEST_ID" || -z "$TOPOLOGY_TYPE" ]]; then
    echo "_parse_topology_json: failed to extract test_id or topology from $toppo_file" >&2
    return 1
  fi

  # Collect partition names by scanning for lines like:
  #     "rootfs-A": {
  # inside the partitions block.  We track depth by counting braces.
  local -a parts=()
  local in_partitions=0
  local depth=0
  local line
  while IFS= read -r line; do
    # Detect opening of the "partitions" object.
    if [[ "$in_partitions" -eq 0 && "$line" == *'"partitions"'* && "$line" == *'{'* ]]; then
      in_partitions=1
      depth=1
      continue
    fi
    if [[ "$in_partitions" -eq 0 ]]; then
      continue
    fi

    # Track brace depth to know when the partitions block ends.
    # NOTE: we cannot use ${line//[^}]/} because } is special in bash
    # glob patterns inside parameter expansion, so we count manually.
    local line_open=0 line_close=0 bi char
    for ((bi = 0; bi < ${#line}; bi++)); do
      char="${line:$bi:1}"
      case "$char" in
        '{') line_open=$((line_open + 1)) ;;
        '}') line_close=$((line_close + 1)) ;;
      esac
    done
    depth=$((depth + line_open - line_close))
    if [[ "$depth" -le 0 ]]; then
      break
    fi

    # Detect a partition key: a quoted string at depth 1 (immediately
    # inside partitions) followed by ": {".
    if [[ "$line" =~ ^[[:space:]]*\"([a-zA-Z0-9_-]+)\":[[:space:]]*\{ ]]; then
      parts+=("${BASH_REMATCH[1]}")
    fi
  done <<<"$content"

  # shellcheck disable=SC2034  # TOPOLOGY_PARTITIONS is part of _parse_topology_json API contract
  TOPOLOGY_PARTITIONS="${parts[*]}"

  # Export per-partition variables.
  # Partition names may contain hyphens (e.g. "rootfs-A") — convert to
  # underscores and upper-case for valid shell identifiers.
  for part in "${parts[@]}"; do
    local var_suffix="${part//-/_}"
    var_suffix="${var_suffix^^}"

    # Extract the three fields for this partition.
    # Strategy: find the line with the partition key, then grab the next
    # few lines which contain uuid, partuuid, and device.
    local block
    block="$(printf '%s\n' "$content" | grep -A5 "\"$part\":")"

    local uuid partuuid device
    uuid="$(printf '%s\n' "$block" | grep -oP '"uuid"\s*:\s*"\K[^"]*' | head -1)"
    partuuid="$(printf '%s\n' "$block" | grep -oP '"partuuid"\s*:\s*"\K[^"]*' | head -1)"
    device="$(printf '%s\n' "$block" | grep -oP '"device"\s*:\s*"\K[^"]*' | head -1)"

    declare -g "TOPOLOGY_${var_suffix}_UUID=$uuid"
    declare -g "TOPOLOGY_${var_suffix}_PARTUUID=$partuuid"
    declare -g "TOPOLOGY_${var_suffix}_DEVICE=$device"
  done

  return 0
}

# ── Query helpers ──────────────────────────────────────────────────────────
# _get_partition_uuid TEST_ID PARTITION
#   Print the UUID for the given partition.
_get_partition_uuid() {
  local test_id="${1:?_get_partition_uuid: missing TEST_ID}"
  local partition="${2:?_get_partition_uuid: missing PARTITION}"
  generate_deterministic_uuid "$test_id" "$partition"
}

# _get_partition_partuuid TEST_ID PARTITION
#   Print the PARTUUID for the given partition.
_get_partition_partuuid() {
  local test_id="${1:?_get_partition_partuuid: missing TEST_ID}"
  local partition="${2:?_get_partition_partuuid: missing PARTITION}"
  generate_deterministic_partuuid "$test_id" "$partition"
}

# _get_slot_device TEST_ID PARTITION
#   Print the device path (/dev/disk/by-partuuid/...) for the partition.
_get_slot_device() {
  local test_id="${1:?_get_slot_device: missing TEST_ID}"
  local partition="${2:?_get_slot_device: missing PARTITION}"
  local partuuid
  partuuid="$(generate_deterministic_partuuid "$test_id" "$partition")"
  printf '/dev/disk/by-partuuid/%s' "$partuuid"
}
