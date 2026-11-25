#!/bin/sh

# Shared BEAM release environment bootstrap for private-network clustering.
# Sources private RFC1918 NIC discovery, rolling-deploy EPMD suffixing,
# and interface-bound Erlang distribution / EPMD ports.

ulimit -n 65536 2>/dev/null || true

is_valid_ipv4() {
  case "$1" in
    ""|.*|*.|*..*|*[!0-9.]*) return 1 ;;
  esac

  old_ifs="$IFS"
  IFS='.'
  # shellcheck disable=SC2086
  set -- $1
  IFS="$old_ifs"

  [ "$#" -eq 4 ] || return 1

  for octet in "$1" "$2" "$3" "$4"; do
    [ -n "$octet" ] && [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] 2>/dev/null || return 1
  done

  return 0
}

is_valid_port() {
  case "$1" in
    ""|*[!0-9]*) return 1 ;;
  esac

  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

# Detect private cluster IP unless explicitly provided via NODE_IP
DETECTED_IP="${NODE_IP:-}"

if [ -z "$DETECTED_IP" ]; then
  DETECTED_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v -E '^(172\.17\.|172\.18\.|172\.20\.)' | head -n 1 || true)
fi

if [ -z "$DETECTED_IP" ]; then
  DETECTED_IP=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^10\.' | head -n 1 || true)
fi

if [ -z "$DETECTED_IP" ]; then
  DETECTED_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v -E '^(172\.17\.|172\.18\.|172\.20\.)' | head -n 1 || true)
fi

if [ -z "$DETECTED_IP" ] || ! is_valid_ipv4 "$DETECTED_IP"; then
  if [ -n "$DETECTED_IP" ]; then
    echo "[tylwyth] WARNING: Ignoring invalid IP address '${DETECTED_IP}', falling back to 127.0.0.1." >&2
  fi
  DETECTED_IP="127.0.0.1"
fi

if [ -z "${RELEASE_COOKIE:-}" ] && [ -n "${CLUSTER_COOKIE:-}" ]; then
  export RELEASE_COOKIE="$CLUSTER_COOKIE"
fi

if [ -z "${RELEASE_COOKIE:-}" ] && [ -n "${DEFAULT_RELEASE_COOKIE:-}" ]; then
  echo "[tylwyth] WARNING: RELEASE_COOKIE is unset; falling back to DEFAULT_RELEASE_COOKIE. Set RELEASE_COOKIE to a strong secret in production." >&2
  export RELEASE_COOKIE="$DEFAULT_RELEASE_COOKIE"
fi

export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-name}"

BASE="${NODE_BASENAME:-app}"
case "$BASE" in
  ""|*[!A-Za-z0-9_-]*)
    echo "[tylwyth] WARNING: Invalid NODE_BASENAME '${BASE}', falling back to 'app'." >&2
    BASE="app"
    ;;
esac

STATIC_PORT="${ERL_DIST_STATIC_PORT:-}"
if [ -n "$STATIC_PORT" ] && ! is_valid_port "$STATIC_PORT"; then
  echo "[tylwyth] WARNING: Ignoring invalid ERL_DIST_STATIC_PORT '${STATIC_PORT}'." >&2
  STATIC_PORT=""
fi

if [ -z "${RELEASE_NODE:-}" ]; then
  if [ -z "$STATIC_PORT" ] && epmd -names 2>/dev/null | grep -F -q "name ${BASE} at port"; then
    SUFFIX=$(head -c 3 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || date +%s | tail -c 5)
    export RELEASE_NODE="${BASE}_${SUFFIX}@${DETECTED_IP}"
  else
    export RELEASE_NODE="${BASE}@${DETECTED_IP}"
  fi
fi

# Constrain Erlang distribution listener (and EPMD, unless using a static port)
DIST_MIN="${ERL_DIST_PORT_MIN:-9100}"
DIST_MAX="${ERL_DIST_PORT_MAX:-9105}"
is_valid_port "$DIST_MIN" || DIST_MIN=9100
is_valid_port "$DIST_MAX" || DIST_MAX=9105
if [ "$DIST_MIN" -gt "$DIST_MAX" ]; then
  DIST_MIN=9100
  DIST_MAX=9105
fi

if [ -n "$STATIC_PORT" ]; then
  LOCAL_HAS_IP=false
  if [ "$DETECTED_IP" != "127.0.0.1" ]; then
    if command -v ip >/dev/null 2>&1; then
      if ip -4 -o addr show 2>/dev/null | grep -F -q " ${DETECTED_IP}/" || ip -4 -o addr show 2>/dev/null | grep -F -q " ${DETECTED_IP} "; then
        LOCAL_HAS_IP=true
      fi
    elif command -v ifconfig >/dev/null 2>&1; then
      if ifconfig 2>/dev/null | grep -F -q "inet ${DETECTED_IP} "; then
        LOCAL_HAS_IP=true
      fi
    fi
  fi

  EPMD_FLAGS="-start_epmd false -erl_epmd_port ${STATIC_PORT}"

  if [ "$LOCAL_HAS_IP" = "true" ] && [ "${ERL_DIST_BIND_INTERFACE:-true}" != "false" ]; then
    IP_TUPLE=$(echo "$DETECTED_IP" | tr '.' ',')
    export ERL_AFLAGS="-kernel inet_dist_listen_min ${STATIC_PORT} inet_dist_listen_max ${STATIC_PORT} inet_dist_use_interface \"{${IP_TUPLE}}\" ${EPMD_FLAGS} ${ERL_AFLAGS:-}"
  else
    export ERL_AFLAGS="-kernel inet_dist_listen_min ${STATIC_PORT} inet_dist_listen_max ${STATIC_PORT} ${EPMD_FLAGS} ${ERL_AFLAGS:-}"
  fi
elif [ "$DETECTED_IP" != "127.0.0.1" ]; then
  IP_TUPLE=$(echo "$DETECTED_IP" | tr '.' ',')
  export ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_MIN} inet_dist_listen_max ${DIST_MAX} inet_dist_use_interface \"{${IP_TUPLE}}\" -start_epmd true ${ERL_AFLAGS:-}"
  export ERL_EPMD_ADDRESS="${DETECTED_IP}"
else
  export ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_MIN} inet_dist_listen_max ${DIST_MAX} -start_epmd true ${ERL_AFLAGS:-}"
fi
