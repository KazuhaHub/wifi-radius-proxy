#!/bin/bash
# Entrypoint of the wifi-radius-proxy image.
#
# What it does, in order:
#   1. Validates the site's settings (the 8 variables of .env) strictly and exits 1 naming every
#      bad item. Nothing is started on a setting that is merely "probably fine".
#   2. Generates /etc/freeradius/clients.conf and proxy.conf from the lists in .env.
#   3. Gets the RADIUS certificate set (server.pem, server.key, ca.pem, SHA256SUMS) from the
#      central certificate service (plain HTTP, Basic auth, this site's own account).
#      A set is accepted only if ALL of these hold:
#        - SHA256SUMS has exactly the three expected lines and the files match it
#        - ca.pem is exactly one certificate whose SHA-256 fingerprint equals the pinned CA_SHA256
#        - server.pem (the leaf, optionally followed by intermediates) chains to that CA and only
#          to that CA (the system trust store is not consulted), is not expired, names
#          radius.kazuha.org in its subjectAltName, and matches server.key
#        - FreeRADIUS really loads it (`freeradius -C` against a temporary copy)
#      Accepted sets are cached in /var/lib/cert-sync; the set that was replaced is kept in
#      /var/lib/cert-sync/previous (if it is itself loadable), so a bad set can be rolled back.
#   4. Runs FreeRADIUS on the newest usable set. If it dies right after start, it falls back
#      to the previous set once, and says so loudly.
#   5. Re-checks the central set every CERT_SYNC_INTERVAL seconds. When a new valid set appears
#      it is cached and the container exits, so Docker restarts it on the new set.
#
# Secrets: they are never written to a file and never logged. The two RADIUS secrets reach
# FreeRADIUS only as environment variables ($ENV{...} in the generated config). The sync
# password is turned into a Basic auth value that is handed only to the fetch subprocess.
# There is no `set -x` anywhere in this script, on purpose.

set -uo pipefail
# ASCII character ranges in the patterns below ([a-z] must not match upper case in some locales).
export LC_ALL=C

log() { echo "wifi-radius-proxy: $*"; }

# --- shutdown handling --------------------------------------------------------------------
# Installed first, so that `docker stop` works at every point, including the first-start wait
# loop. Bash runs a trap only when the foreground command ends, so everything that can take a
# while (fetches, sleeps, freeradius -C) runs in the background and is waited for with `wait`,
# which a signal interrupts at once. `child` is the current background job, `fr` is FreeRADIUS.
child=""
fr=""
logcat=""   # tail, copying the login log (a small file, see below) to the container log
logtrim=""  # the loop that keeps that file small
# Scratch space for downloads and checks. A pulled set contains server.key, so this directory is
# removed on TERM and also emptied at every start (a container restart keeps its /tmp, and a
# killed run could have left files behind).
WORK=/tmp/wifi-radius-proxy-work
rm -rf "$WORK"; mkdir -m 755 "$WORK"
on_term() {
  trap '' TERM INT
  [ -n "$child" ] && kill "$child" 2>/dev/null
  rm -rf "$WORK"
  if [ -n "$fr" ]; then
    log "stopping FreeRADIUS"
    kill -TERM "$fr" 2>/dev/null
    wait "$fr" 2>/dev/null   # a clean FreeRADIUS shutdown, not a kill after the Docker grace period
  fi
  [ -n "$logcat" ] && kill "$logcat" 2>/dev/null
  [ -n "$logtrim" ] && kill "$logtrim" 2>/dev/null
  log "stopped"
  exit 0
}
trap on_term TERM INT

bg() {  # run a command in the background and wait for it; returns its exit status
  "$@" &
  child=$!
  wait "$child"
  local rc=$?
  child=""
  return $rc
}

# --- settings: validation ---------------------------------------------------------------------
# Why so strict: these values end up in a generated FreeRADIUS configuration, in an HTTP request
# and in the log. A typo should stop the container with a clear message at start, not show up
# later as an AP that cannot log in. No variable has a default here; a missing one is an error.
errors=()
err() { errors+=("$*"); }

OCT='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'     # 0-255, no leading zeros
IPV4_RE="^${OCT}(\\.${OCT}){3}\$"
is_ipv4() { [[ $1 =~ $IPV4_RE ]]; }
is_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
is_net() {  # IPv4 address or IPv4/prefix (0-32)
  is_ipv4 "${1%%/*}" || return 1
  [[ $1 != */* ]] || [[ ${1#*/} =~ ^(3[0-2]|[12]?[0-9])$ ]]
}
# AP_SUBNETS policy, on top of the format check. These entries become RADIUS clients, so a typo
# must not be able to open the server to a huge range or to everyone.
ap_policy() {  # entry -> message on stdout and status 1 if the entry is not acceptable
  local a=${1%%/*} len=32
  [[ $1 == */* ]] && len=${1#*/}
  if [[ $a == 0.* ]]; then
    echo "starts with 0 (0.0.0.0 means every address); that would let anyone send RADIUS requests"; return 1
  fi
  if [ "$len" -lt 8 ]; then
    echo "prefix /$len is shorter than /8; that is too wide for an AP network (a typo?)"; return 1
  fi
  if [[ $a == 127.* ]] && [ "${ALLOW_LOOPBACK_AP:-}" != 1 ]; then
    echo "is a loopback address (127.0.0.0/8); only allowed for tests with ALLOW_LOOPBACK_AP=1"; return 1
  fi
  return 0
}

is_server() {  # IPv4:port
  [[ $1 == *:* ]] && is_ipv4 "${1%:*}" && is_port "${1##*:}"
}

check_list() {  # VAR validator "what an item must be"
  local var=$1 fn=$2 what=$3 v=${!1:-} item
  local -a items
  if [[ $v == ,* || $v == *, || $v == *,,* ]]; then err "$var has an empty entry (stray comma)"; return; fi
  IFS=, read -ra items <<< "$v"
  for item in "${items[@]}"; do
    "$fn" "$item" || err "$var: $(printf '%q' "$item") is not $what"
  done
}

check_secret() {  # VAR: never prints the value
  local var=$1 v=${!1:-} c bad=""
  for c in '"' '\' '$' '{' '}' '#'; do
    [[ $v == *"$c"* ]] && bad+=" $c"
  done
  [[ $v =~ [[:cntrl:]] ]] && bad+=" (a newline or other control character)"
  if [ -n "$bad" ]; then
    err "$var contains forbidden character(s):$bad. These are special in FreeRADIUS configuration or in .env files and could break parsing or quoting, or be changed silently. Use letters and digits, e.g. the output of: openssl rand -hex 16"
  fi
}

missing=()
for v in SITE_NAME AP_SUBNETS AP_RADIUS_SECRET CENTRAL_SERVERS CENTRAL_SECRET \
         CERT_SYNC_URL CERT_SYNC_USER CERT_SYNC_PASSWORD; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
[ ${#missing[@]} -eq 0 ] || err "missing or empty in .env: ${missing[*]} (see .env.example)"

if [ -n "${SITE_NAME:-}" ] && ! [[ $SITE_NAME =~ ^[a-z0-9-]{1,32}$ ]]; then
  err "SITE_NAME must be 1-32 characters from a-z, 0-9 and '-'"
fi
if [ -n "${AP_SUBNETS:-}" ]; then
  n_before=${#errors[@]}
  check_list AP_SUBNETS is_net "an IPv4 address or CIDR (e.g. 192.168.10.0/24)"
  if [ ${#errors[@]} -eq "$n_before" ]; then      # well-formed: now the policy
    IFS=, read -ra _aps <<< "$AP_SUBNETS"
    for item in "${_aps[@]}"; do
      msg=$(ap_policy "$item") || err "AP_SUBNETS: $item $msg"
    done
  fi
fi
[ -z "${CENTRAL_SERVERS:-}" ] || check_list CENTRAL_SERVERS is_server "IPv4:port (e.g. 203.0.113.10:1812)"
for v in AP_RADIUS_SECRET CENTRAL_SECRET CERT_SYNC_PASSWORD; do
  [ -z "${!v:-}" ] || check_secret "$v"
done
if [ -n "${CERT_SYNC_USER:-}" ]; then
  check_secret CERT_SYNC_USER
  [[ $CERT_SYNC_USER != *:* ]] || err "CERT_SYNC_USER must not contain ':' (it separates user and password in Basic auth)"
fi

# CERT_SYNC_URL: one or more certificate services, comma-separated, in fail-over order. Each check
# tries them in order and takes the whole set from the first one that delivers a usable set.
SRC_LIST=()      # host:port
SRC_HOST=""; SRC_PORT=""   # the one being tried (or last used)
is_cert_url() {  # http://IPv4:port; on success the host:port is added to SRC_LIST
  # Take the two parts out first: is_ipv4 and is_port run their own regex matches, which would
  # overwrite BASH_REMATCH.
  [[ $1 =~ ^http://([0-9.]+):([0-9]+)$ ]] || return 1
  local h=${BASH_REMATCH[1]} q=${BASH_REMATCH[2]}
  is_ipv4 "$h" && is_port "$q" && SRC_LIST+=("$h:$q")
}
if [ -n "${CERT_SYNC_URL:-}" ]; then
  if [[ $CERT_SYNC_URL == *[[:cntrl:]]* ]]; then err "CERT_SYNC_URL contains a newline or other control character"
  else check_list CERT_SYNC_URL is_cert_url "http://IPv4:port, plain http, no path (e.g. http://203.0.113.10:8080)"; fi
fi

# Optional knobs for tests and tuning. They are generic, so they do have defaults.
INTERVAL=${CERT_SYNC_INTERVAL:-21600}   # seconds between checks of the central set (6 h)
LISTEN_PORT=${LISTEN_PORT:-1812}        # UDP port the site listens on for the APs
[[ $INTERVAL =~ ^[1-9][0-9]{0,6}$ ]] || err "CERT_SYNC_INTERVAL must be a number of seconds (optional, default 21600)"
is_port "$LISTEN_PORT" || err "LISTEN_PORT must be a port 1-65535 (optional, default 1812)"
[ -z "${ALLOW_LOOPBACK_AP:-}" ] || [ "$ALLOW_LOOPBACK_AP" = 1 ] || err "ALLOW_LOOPBACK_AP must be 1 or unset (optional, tests only)"

# The pinned CA fingerprint comes from the image (see the Dockerfile); compare without colons, ignoring case.
CA_PIN=${CA_SHA256:-}; CA_PIN=${CA_PIN//:/}; CA_PIN=${CA_PIN^^}
[[ $CA_PIN =~ ^[0-9A-F]{64}$ ]] || err "CA_SHA256 (pinned CA fingerprint, baked into the image) is not a SHA-256 fingerprint"
# The image's own value, kept in a file written at build time, so that a run-time override of
# CA_SHA256 (meant for tests) cannot go unnoticed.
BUILTIN_CA=$(cat /usr/local/share/wifi-radius-proxy/ca-sha256 2>/dev/null) || BUILTIN_CA=""
BUILTIN_CA=${BUILTIN_CA//:/}; BUILTIN_CA=${BUILTIN_CA^^}
[[ $BUILTIN_CA =~ ^[0-9A-F]{64}$ ]] || err "the image's built-in CA fingerprint (/usr/local/share/wifi-radius-proxy/ca-sha256) is missing or damaged"

if [ ${#errors[@]} -gt 0 ]; then
  for e in "${errors[@]}"; do log "invalid setting: $e"; done
  exit 1
fi

if [ "$CA_PIN" != "$BUILTIN_CA" ]; then
  log "WARNING: CA_SHA256 is overridden and differs from the CA fingerprint built into this image."
  log "WARNING:   in use:   $CA_PIN"
  log "WARNING:   built-in: $BUILTIN_CA"
  log "WARNING: this is for tests only; on a real site, remove CA_SHA256 from the environment."
fi
IFS=, read -ra AP_LIST <<< "$AP_SUBNETS"
IFS=, read -ra CENTRAL_LIST <<< "$CENTRAL_SERVERS"
export LISTEN_PORT
RETRY=30    # seconds between attempts while no usable certificate set exists yet
GRACE=5     # seconds FreeRADIUS must stay up after start before it counts as started
NAME=radius.kazuha.org
CACHE=/var/lib/cert-sync
LIVE=/etc/freeradius/certs-site
export SITE_CERT_DIR=$LIVE     # read by mods-enabled/eap; overridden for the pre-check
FILES="server.pem server.key ca.pem"
AUTH=$(printf '%s:%s' "$CERT_SYNC_USER" "$CERT_SYNC_PASSWORD" | base64 -w0)
unset CERT_SYNC_USER CERT_SYNC_PASSWORD   # FreeRADIUS and the other children do not need them

# --- generated FreeRADIUS configuration -------------------------------------------------------
# clients.conf and proxy.conf are built from the lists in .env instead of being templates, because
# the number of AP subnets and central servers differs per site. The secrets are written as
# $ENV{...} references and never as values: no file, image layer or `docker cp` ever holds them.
write_conf() {  # path; the content comes on stdin. root:freerad 640, swapped in atomically.
  local path=$1
  ( umask 027; cat > "$path.new" ) &&
    chown root:freerad "$path.new" && chmod 640 "$path.new" && mv -f "$path.new" "$path"
}

gen_clients() {
  local i=0 net
  {
    echo "# Generated by wifi-radius-proxy at container start from AP_SUBNETS. Do not edit."
    echo "# One client per AP subnet; all share AP_RADIUS_SECRET, which is read from the environment."
    for net in "${AP_LIST[@]}"; do
      i=$((i + 1))
      cat <<EOF

client site-lan-$i {
	ipaddr = $net
	secret = \$ENV{AP_RADIUS_SECRET}
	require_message_authenticator = auto
	limit_proxy_state = auto
	shortname = $SITE_NAME-$i
}
EOF
    done
  } | write_conf /etc/freeradius/clients.conf
}

gen_proxy() {
  local i=0 s
  {
    cat <<'EOF'
# Generated by wifi-radius-proxy at container start from CENTRAL_SERVERS. Do not edit.
# Only the inner (tunneled) PAP request is proxied, explicitly via Proxy-To-Realm = ENTRA.
# The central servers are tried in the order of CENTRAL_SERVERS (the first is the primary,
# the others are backups) and all share CENTRAL_SECRET, read from the environment.
# Each is probed with Status-Server every 30 s once it stops answering, so a dead server is
# skipped before user requests time out, and is used again after 3 answers.
proxy server {
	default_fallback = no
}
EOF
    for s in "${CENTRAL_LIST[@]}"; do
      i=$((i + 1))
      cat <<EOF

home_server central_$i {
	type = auth
	ipaddr = ${s%:*}
	port = ${s##*:}
	secret = \$ENV{CENTRAL_SECRET}
	require_message_authenticator = yes
	response_window = 15
	zombie_period = 40
	status_check = status-server
	check_interval = 30
	check_timeout = 4
	num_answers_to_alive = 3
}
EOF
    done
    echo
    echo "home_server_pool central {"
    echo "	type = fail-over"
    for ((s = 1; s <= i; s++)); do echo "	home_server = central_$s"; done
    echo "}"
    cat <<'EOF'

realm ENTRA {
	auth_pool = central
	nostrip
}
EOF
  } | write_conf /etc/freeradius/proxy.conf
}

gen_clients && gen_proxy || { log "cannot write the generated configuration in /etc/freeradius"; exit 1; }

# The login log (mods-enabled/login_log): one line per login, written by FreeRADIUS's linelog modules to
# a small file and copied by `tail -F` to the container's stdout, so the lines are in `docker logs` and rotate
# with them. Not /dev/stdout: FreeRADIUS runs as freerad after start and cannot open the pipe, which belongs
# to root (and linelog seeks, which a pipe or a FIFO refuses). The file cannot grow without bound: it is
# emptied when it passes 1 MiB (tail follows the truncation). A line written in the instant of the
# emptying could be lost from the container log; at the rate of Wi-Fi logins that is not a practical risk.
LOGIN_DIR=/run/wifi-radius-proxy
LOGIN_LOG=$LOGIN_DIR/logins.log
rm -rf "$LOGIN_DIR"; mkdir -m 750 "$LOGIN_DIR" && chown freerad:freerad "$LOGIN_DIR" \
  && : > "$LOGIN_LOG" && chown freerad:freerad "$LOGIN_LOG" && chmod 640 "$LOGIN_LOG" \
  || { log "cannot create $LOGIN_LOG"; exit 1; }
tail -n 0 -F "$LOGIN_LOG" 2>/dev/null &
logcat=$!
( while sleep 30; do [ "$(stat -c %s "$LOGIN_LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && : > "$LOGIN_LOG"; done ) &
logtrim=$!

# --- certificate set ----------------------------------------------------------------------
# GET one file over plain HTTP; body to stdout, fails unless the answer is 200. Plain HTTP is
# acceptable only because the service is on a private network; what makes a set trustworthy is
# not the channel but the checks in valid_set (above all the pinned CA).
get() {
  exec 3<>"/dev/tcp/$SRC_HOST/$SRC_PORT" || return 1
  printf 'GET /%s HTTP/1.0\r\nHost: %s\r\nAuthorization: Basic %s\r\n\r\n' "$1" "$SRC_HOST" "$AUTH" >&3
  local status line
  IFS= read -r status <&3 || return 1
  case "$status" in *" 200 "*) ;; *) echo "${status%$'\r'}" >&2; exec 3<&-; return 1 ;; esac
  while IFS= read -r line <&3; do [ -z "${line%$'\r'}" ] && break; done
  head -c 1048576 <&3     # a certificate file is a few KB; refuse to be filled up
  exec 3<&-
}
GET_FN=$(declare -f get)

fetch() {  # name outfile errfile. In the background so a TERM is handled at once; 30 s limit.
  # The Basic auth value is given to this one process only, as an environment variable (not argv).
  AUTH=$AUTH SRC_HOST=$SRC_HOST SRC_PORT=$SRC_PORT \
    timeout 30 bash -c "$GET_FN"'; get "$1"' _ "$1" > "$2" 2> "$3" &
  child=$!
  wait "$child"
  local rc=$?
  child=""
  return $rc
}

why=""   # the reason the last check failed, for the log

sums_ok() {  # dir: SHA256SUMS is exactly the expected three lines, and the files match it
  local f=$1/SHA256SUMS
  [ -s "$f" ] || { why="SHA256SUMS is missing"; return 1; }
  # Checked before sha256sum ever sees the file: sha256sum -c opens whatever path a line names
  # (a /dev/zero line would hang it). Exactly "<64 hex>  <name>" for our three names, each once.
  [ "$(wc -l < "$f")" = 3 ] \
    && ! grep -qvE '^[0-9a-fA-F]{64}  (server\.pem|server\.key|ca\.pem)$' "$f" \
    && [ "$(cut -c67- "$f" | sort | tr '\n' ' ')" = "ca.pem server.key server.pem " ] \
    || { why="SHA256SUMS must be exactly three lines, '<64 hex>  <name>', for server.pem, server.key and ca.pem"; return 1; }
  # In the background like every other slow step, so a TERM is handled at once.
  bg sh -c 'cd "$1" && exec sha256sum -c --quiet --strict SHA256SUMS' _ "$1" >/dev/null 2>&1 \
    || { why="the files do not match SHA256SUMS"; return 1; }
}

valid_set() {  # dir: the cryptographic checks (see the header)
  local w rc
  w=$(mktemp -d -p "$WORK") || { why="cannot create a temporary directory"; return 1; }
  valid_set_in "$1" "$w"; rc=$?
  rm -rf "$w"
  return $rc
}

valid_set_in() {  # dir workdir
  local d=$1 w=$2 f n fp out
  local -a verify=(-CAfile "$d/ca.pem" -no-CApath -no-CAstore)
  for f in $FILES; do [ -s "$d/$f" ] || { why="$f is missing or empty"; return 1; }; done

  # Trust anchor. ca.pem must be one certificate and must be THE pinned CA. "One" matters:
  # openssl verify trusts every certificate in the file, while a fingerprint covers only the first.
  n=$(grep -c -- '-----BEGIN' "$d/ca.pem")
  [ "$n" = 1 ] || { why="ca.pem must contain exactly one certificate (found $n PEM blocks)"; return 1; }
  fp=$(openssl x509 -in "$d/ca.pem" -noout -fingerprint -sha256 2>/dev/null) || { why="ca.pem is not a certificate"; return 1; }
  fp=${fp#*=}; fp=${fp//:/}; fp=${fp^^}
  [ "$fp" = "$CA_PIN" ] || { why="ca.pem fingerprint $fp does not match the pinned CA_SHA256"; return 1; }

  # server.pem is the leaf, optionally followed by intermediates. Verify the leaf alone, with the
  # rest only as "untrusted" helpers to build the path; the only trust anchor is the pinned
  # ca.pem. -no-CApath/-no-CAstore matter: without them openssl also trusts the system store,
  # so a leaf from any public or locally installed CA would verify even though ca.pem is not its issuer.
  openssl x509 -in "$d/server.pem" -out "$w/leaf.pem" 2>/dev/null || { why="server.pem holds no readable certificate"; return 1; }
  awk '/-----BEGIN CERTIFICATE-----/{n++} n>1' "$d/server.pem" > "$w/chain.pem"
  [ ! -s "$w/chain.pem" ] || verify+=(-untrusted "$w/chain.pem")
  out=$(openssl verify "${verify[@]}" "$w/leaf.pem" 2>&1) && [[ $out == *": OK" ]] \
    || { why="server.pem does not chain to the pinned ca.pem"; return 1; }
  openssl x509 -in "$w/leaf.pem" -noout -checkend 0 >/dev/null 2>&1 || { why="server.pem is expired"; return 1; }

  # The name: one of the DNS entries of subjectAltName must be exactly $NAME. Parsed entry by
  # entry and compared whole, so radius.kazuha.org.evil.example or x-radius.kazuha.org do not pass.
  openssl x509 -in "$w/leaf.pem" -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -Fxq "DNS:$NAME" \
    || { why="server.pem has no subjectAltName DNS entry equal to $NAME"; return 1; }

  [ "$(openssl x509 -in "$w/leaf.pem" -noout -pubkey | openssl sha256)" = \
    "$(openssl pkey -in "$d/server.key" -pubout 2>/dev/null | openssl sha256)" ] \
    || { why="server.key does not match server.pem"; return 1; }
}

install_set() {  # src dst: copy a set with the owner and modes FreeRADIUS expects
  local f
  mkdir -p "$2" && chown root:freerad "$2" && chmod 750 "$2" || return 1
  for f in $FILES; do cp "$1/$f" "$2/$f" || return 1; done
  chown root:freerad "$2"/* && chmod 644 "$2"/*.pem && chmod 640 "$2/server.key"
}

# Does FreeRADIUS itself accept this set? valid_set cannot know what the TLS library will
# refuse (a too-small key for the security level, an unsupported algorithm, ...). So the set is
# copied to a temporary directory and `freeradius -C` is run with the certificate paths pointing
# there. A refusal is found before the set can replace anything that works.
fr_check() {  # dir [quiet]: with "quiet" a refusal is not logged (the caller reports it)
  local stg log_file rc
  stg=$(mktemp -d -p "$WORK" stage.XXXXXX) || return 1
  # FreeRADIUS drops to its own user before it reads the key, so it must be able to enter this
  # directory (mktemp makes it 700). The key file itself stays root:freerad 640.
  chmod 755 "$stg"
  log_file="$stg/check.log"
  if install_set "$1" "$stg/set"; then
    bg env SITE_CERT_DIR="$stg/set" freeradius -C -l stdout > "$log_file" 2>&1
    rc=$?
  else
    rc=1; echo "cannot copy the set to a temporary directory" > "$log_file"
  fi
  if [ $rc -ne 0 ] && [ "${2:-}" != quiet ]; then
    log "FreeRADIUS refuses this certificate set:"
    grep -viE 'secret|password' "$log_file" | tail -n 8 | sed 's/^/wifi-radius-proxy:   /'
  fi
  rm -rf "$stg"
  return $rc
}

usable() {  # dir: complete, verified and loadable
  sums_ok "$1" && valid_set "$1" || { log "set in $1 is not usable: $why"; return 1; }
  fr_check "$1"
}

adopt() {  # dir: make a verified set the current one, keeping the one it replaces as previous/
  local d=$1 f
  mkdir -p "$CACHE" && chmod 700 "$CACHE"
  # Keep the old set as previous/ only if FreeRADIUS really loads it. A previous/ that does not
  # load is no use as a roll-back, so a broken current set must never overwrite a good previous/.
  if [ -e "$CACHE/server.pem" ]; then
    if sums_ok "$CACHE" && valid_set "$CACHE" && fr_check "$CACHE" quiet; then
      rm -rf "$CACHE/.previous.new"; mkdir -m 700 "$CACHE/.previous.new"
      for f in $FILES SHA256SUMS; do cp "$CACHE/$f" "$CACHE/.previous.new/$f"; done
      rm -rf "$CACHE/previous"; mv "$CACHE/.previous.new" "$CACHE/previous"
    else
      log "the current cached set is not loadable; keeping the existing previous/ as it is"
    fi
  fi
  for f in $FILES SHA256SUMS; do install -m 600 "$d/$f" "$CACHE/.$f.new"; done
  for f in $FILES SHA256SUMS; do mv -f "$CACHE/.$f.new" "$CACHE/$f"; done
}

# Pull the central set from each service in CERT_SYNC_URL in turn, until one gives a result:
# 0 = a new set was verified and cached, 1 = unchanged, 2 = every service failed (the cache is
# left alone). The whole set always comes from one service.
pull() {
  local s
  for s in "${SRC_LIST[@]}"; do
    SRC_HOST=${s%:*}; SRC_PORT=${s##*:}
    pull_one && return 0
    [ $? -eq 1 ] && return 1
  done
  [ "${#SRC_LIST[@]}" -gt 1 ] && log "no certificate service gave a usable set (tried ${CERT_SYNC_URL//,/, })"
  return 2
}

# Pull from $SRC_HOST:$SRC_PORT. 0 = a new set was verified and cached, 1 = unchanged, 2 = failed.
# "Unchanged" needs more than equal SHA256SUMS: the cached files must still pass the sums and the
# checks, otherwise the set is fetched again.
pull_one() {
  local t f
  t=$(mktemp -d -p "$WORK" pull.XXXXXX) || return 2
  if ! fetch SHA256SUMS "$t/SHA256SUMS" "$t/err" || [ ! -s "$t/SHA256SUMS" ]; then
    log "cannot get the certificate set from $SRC_HOST:$SRC_PORT ($(head -n1 "$t/err" 2>/dev/null))"
    rm -rf "$t"; return 2
  fi
  if cmp -s "$t/SHA256SUMS" "$CACHE/SHA256SUMS" && sums_ok "$CACHE" && valid_set "$CACHE"; then
    rm -rf "$t"; return 1
  fi
  for f in $FILES; do
    if ! fetch "$f" "$t/$f" "$t/err"; then
      log "cannot get $f from $SRC_HOST:$SRC_PORT ($(head -n1 "$t/err" 2>/dev/null))"
      rm -rf "$t"; return 2
    fi
  done
  if ! sums_ok "$t" || ! valid_set "$t"; then
    log "the set from $SRC_HOST:$SRC_PORT was rejected: $why"; rm -rf "$t"; return 2
  fi
  if ! fr_check "$t"; then
    log "the set from $SRC_HOST:$SRC_PORT was rejected: FreeRADIUS cannot load it; keeping the current set"
    rm -rf "$t"; return 2
  fi
  adopt "$t"; rm -rf "$t"
  return 0
}

# --- start --------------------------------------------------------------------------------
LIVE_FROM=""
select_live() {  # install the newest usable set into $LIVE: the current one, else previous/
  local d
  for d in "$CACHE" "$CACHE/previous"; do
    [ -d "$d" ] && usable "$d" || continue
    install_set "$d" "$LIVE" || { log "cannot install the set into $LIVE"; return 1; }
    if [ "$d" = "$CACHE" ]; then LIVE_FROM=current
    else
      LIVE_FROM=previous
      log "WARNING: the current cached certificate set is unusable; running on the PREVIOUS set ($CACHE/previous). Check the central service."
    fi
    return 0
  done
  return 1
}

pull; r=$?
case $r in
  0) log "got a new certificate set from $SRC_HOST:$SRC_PORT" ;;
  1) log "certificate set unchanged" ;;
esac
until select_live; do
  log "no valid certificate set yet (first start needs the central certificate service and this site's account); retrying in ${RETRY}s"
  bg sleep "$RETRY"
  pull
done

log "site $SITE_NAME: cert $(openssl x509 -in "$LIVE/server.pem" -noout -enddate), CA $(openssl x509 -in "$LIVE/ca.pem" -noout -enddate)"
log "${#AP_LIST[@]} AP subnet(s): $AP_SUBNETS; central in fail-over order: ${CENTRAL_SERVERS//,/, }"

start_fr() { freeradius -f -l stdout & fr=$!; }

# True if FreeRADIUS died within the grace period. The status is left in $frc.
died_early() {
  local sp who=""
  sleep "$GRACE" & sp=$!; child=$sp
  wait -n -p who "$fr" "$sp"; frc=$?
  child=""
  [ "$who" = "$fr" ] || return 1
  kill "$sp" 2>/dev/null
  return 0
}

start_fr
if died_early; then
  log "FreeRADIUS exited at start ($frc)"
  # One fall-back, to the set that was in use before the current one.
  if [ "$LIVE_FROM" = current ] && [ -d "$CACHE/previous" ] && usable "$CACHE/previous" \
     && install_set "$CACHE/previous" "$LIVE"; then
    LIVE_FROM=previous
    log "!!! ROLLING BACK: FreeRADIUS would not start on the current certificate set; starting on the PREVIOUS one ($CACHE/previous). Investigate the central set."
    start_fr
    if died_early; then log "FreeRADIUS does not start on the previous set either"; exit 1; fi
  else
    exit "$frc"
  fi
fi

while :; do
  sleep "$INTERVAL" & sp=$!; child=$sp
  who=""
  wait -n -p who "$fr" "$sp"; rc=$?
  child=""
  if [ "$who" = "$fr" ]; then kill "$sp" 2>/dev/null; log "FreeRADIUS exited ($rc)"; exit "$rc"; fi
  pull
  if [ $? -eq 0 ]; then
    log "new certificate set from $SRC_HOST:$SRC_PORT, restarting to load it"
    kill -TERM "$fr"; wait "$fr"
    exit 0
  fi
done
