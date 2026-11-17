#!/bin/bash
# End-to-end test of a built site image, with no real secrets and nothing outside this host:
#   a throwaway CA and server certs, a certificate service (nginx + Basic auth) and a fake central
#   FreeRADIUS that accepts one test user with PAP, all on 127.0.0.x with host networking.
# Then, with eapol_test as the AP + client:
#   1. a correct password over EAP-TTLS/PAP is accepted, a wrong one rejected; the generated
#      config holds no secret and has the right owner and mode
#   2. a new certificate set on the service makes the container exit; after a restart it serves the new cert
#   3. a wrong certificate-service password leaves a fresh site waiting, not running; docker stop is quick and clean
#   4. two central servers, the first one down: once it is detected (one login may time out), logins work through the second
#   5. a set whose CA does not match the pinned fingerprint is rejected on a fresh cache
#   6. a set that passes the certificate checks but that FreeRADIUS refuses is not adopted; the
#      running set stays live; docker stop on the running site is quick and clean
#   7. at boot, an unusable current cached set falls back to previous/
#   8. a broken current set never overwrites a good previous/ when a new set is adopted
#   9. a leaf issued through an intermediate (server.pem = leaf + intermediate) is accepted
#  10. a leaf from a CA that is in the image's system trust store but is not the pinned CA is rejected
#  11. a SHA256SUMS with an extra line (/dev/zero) is rejected quickly
#  12. invalid .env items (formats, AP_SUBNETS policy, secrets): exit 1 with a message naming each, no secret in the output
# The image's own CA_SHA256 is overridden with the throwaway CA's fingerprint (except in case 5),
# which makes the image log a warning; the test checks for it.
# Usage: test/e2e.sh IMAGE      (needs docker, openssl, eapol_test)
set -euo pipefail

IMAGE=${1:?usage: $0 IMAGE}
P=krs-e2e-$$
CERT_PORT=${E2E_CERT_PORT:-18880}
CENTRAL_PORT=${E2E_CENTRAL_PORT:-18113}
SITE_PORT=${E2E_SITE_PORT:-18812}
T=$(mktemp -d)
pass=0; fail=0

cleanup() {
  docker rm -f "$P-site" "$P-certs" "$P-central" "$P-env" "$P-seed" >/dev/null 2>&1 || true
  docker rmi -f "$P-rogue:test" >/dev/null 2>&1 || true
  docker volume rm "$P-cache" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

wait_log() {  # container pattern seconds
  local i
  for ((i = 0; i < $3; i++)); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    sleep 1
  done
  return 1
}

# --- throwaway PKI -------------------------------------------------------------------------
mkdir -p "$T/pki" "$T/dist" "$T/central"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=e2e test CA" \
  -keyout "$T/pki/ca.key" -out "$T/pki/ca.pem" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
# The pin, in the form most unlike the image default (lower case, no colons) to exercise the normalisation.
CA_FP=$(openssl x509 -in "$T/pki/ca.pem" -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d : | tr 'A-F' 'a-f')
issue() {  # dir [rsa bits] [ca.pem ca.key]
  local bits=${2:-2048} cacert=${3:-$T/pki/ca.pem} cakey=${4:-$T/pki/ca.key}
  openssl req -newkey "rsa:$bits" -nodes -subj "/CN=radius.kazuha.org" -keyout "$1/server.key" -out "$1/server.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:radius.kazuha.org\n' > "$1/ext"
  openssl x509 -req -in "$1/server.csr" -CA "$cacert" -CAkey "$cakey" -CAcreateserial \
    -days 2 -extfile "$1/ext" -out "$1/server.pem" 2>/dev/null
  rm -f "$1/server.csr" "$1/ext"
  cp "$cacert" "$1/ca.pem"
}
issue_chain() {  # dir: server.pem = leaf + intermediate, ca.pem = the root
  openssl req -newkey rsa:2048 -nodes -subj "/CN=e2e test intermediate" -keyout "$1/inter.key" -out "$1/inter.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$1/inter.ext"
  openssl x509 -req -in "$1/inter.csr" -CA "$T/pki/ca.pem" -CAkey "$T/pki/ca.key" -CAcreateserial \
    -days 2 -extfile "$1/inter.ext" -out "$1/inter.pem" 2>/dev/null
  issue "$1" 2048 "$1/inter.pem" "$1/inter.key"
  cat "$1/inter.pem" >> "$1/server.pem"
  cp "$T/pki/ca.pem" "$1/ca.pem"
}
publish() {  # dir with server.pem/key/ca.pem
  cp "$1/server.pem" "$1/server.key" "$1/ca.pem" "$T/dist/"
  (cd "$T/dist" && sha256sum server.pem server.key ca.pem > SHA256SUMS)
  chmod 644 "$T/dist"/*
}
mkdir -p "$T/set1" "$T/set2" "$T/weak"
issue "$T/set1"; issue "$T/set2"
issue "$T/weak" 1024          # an RSA-1024 leaf: chains, not expired, right name, key matches
publish "$T/set1"

# --- certificate service ---------------------------------------------------------------------
SYNC_PW=$(openssl rand -hex 16)
printf 'e2e-site:%s\n' "$(openssl passwd -apr1 "$SYNC_PW")" > "$T/htpasswd"
chmod 644 "$T/htpasswd"
cat > "$T/nginx.conf" <<EOF
server {
    listen 127.0.0.1:$CERT_PORT;
    auth_basic "cert-dist";
    auth_basic_user_file /etc/nginx/htpasswd;
    root /srv/certs;
    location ~ ^/(SHA256SUMS|server\.pem|server\.key|ca\.pem)\$ { default_type text/plain; }
    location / { return 404; }
}
EOF
docker run -d --name "$P-certs" --network host \
  -v "$T/dist:/srv/certs:ro" -v "$T/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$T/htpasswd:/etc/nginx/htpasswd:ro" nginx:1.29-alpine >/dev/null

# --- fake central: PAP against one local user --------------------------------------------------
CENTRAL_SECRET=$(openssl rand -hex 16)
cat > "$T/central/default" <<EOF
server default {
	listen {
		type = auth
		ipaddr = 127.0.0.1
		port = $CENTRAL_PORT
	}
	authorize {
		Autz-Type Status-Server {
			ok
		}
		files
		pap
	}
	authenticate {
		pap
	}
}
EOF
printf 'client local {\n\tipaddr = 127.0.0.1\n\tsecret = %s\n}\n' "$CENTRAL_SECRET" > "$T/central/clients.conf"
printf 'alice Cleartext-Password := "correct-horse"\n' > "$T/central/authorize"
chmod 644 "$T/central"/*
docker run -d --name "$P-central" --network host --entrypoint sh \
  -v "$T/central:/e2e:ro" "$IMAGE" -c '
    rm -f /etc/freeradius/sites-enabled/*
    cp /e2e/default /etc/freeradius/sites-enabled/default
    cp /e2e/clients.conf /etc/freeradius/clients.conf
    cp /e2e/authorize /etc/freeradius/mods-config/files/authorize
    printf "proxy server {\n}\n" > /etc/freeradius/proxy.conf
    rm -f /etc/freeradius/mods-enabled/eap
    exec freeradius -f -l stdout' >/dev/null
wait_log "$P-central" "Ready to process requests" 20 || { docker logs "$P-central" | tail -20; echo "fake central did not start"; exit 1; }

# --- the site under test ----------------------------------------------------------------------
AP_SECRET=$(openssl rand -hex 16)
# SITE_IMAGE (optional) replaces the image under test, for the case with a modified trust store.
# site PASSWORD [NAME=value ...]: start the site; the NAME=value pairs override the default .env.
# The value <default> removes a variable, so the image's own default applies.
site() {
  local pw=$1; shift
  local -A e=(
    [SITE_NAME]=e2e [AP_SUBNETS]=127.0.0.1/32 [AP_RADIUS_SECRET]=$AP_SECRET
    [CENTRAL_SERVERS]=127.0.0.1:$CENTRAL_PORT [CENTRAL_SECRET]=$CENTRAL_SECRET
    [CERT_SYNC_URL]=http://127.0.0.1:9,http://127.0.0.1:$CERT_PORT [CERT_SYNC_USER]=e2e-site [CERT_SYNC_PASSWORD]=$pw
    [CA_SHA256]=$CA_FP [LISTEN_PORT]=$SITE_PORT [CERT_SYNC_INTERVAL]=5 [ALLOW_LOOPBACK_AP]=1
  )
  local kv k args=()
  for kv in "$@"; do e[${kv%%=*}]=${kv#*=}; done
  for k in "${!e[@]}"; do [ "${e[$k]}" = "<default>" ] || args+=(-e "$k=${e[$k]}"); done
  docker run -d --name "$P-site" --network host -v "$P-cache:/var/lib/cert-sync" "${args[@]}" "${SITE_IMAGE:-$IMAGE}" >/dev/null
}
eap() {  # user password [server-cert-out]
  local conf="$T/eapol.conf"
  printf 'network={\n key_mgmt=WPA-EAP\n eap=TTLS\n identity="%s"\n anonymous_identity="anonymous@kazuha.org"\n password="%s"\n phase2="auth=PAP"\n ca_cert="%s"\n domain_match="radius.kazuha.org"\n}\n' \
    "$1" "$2" "$T/pki/ca.pem" > "$conf"
  eapol_test -c "$conf" -a 127.0.0.1 -p "$SITE_PORT" -s "$AP_SECRET" -t 40 ${3:+-o"$3"} 2>&1 | tail -1
}
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }
served_leaf() {  # eapol_test -o writes every received cert (CA first): keep the radius.kazuha.org one
  rm -f "$T"/served-*.pem
  awk -v d="$T" '/BEGIN CERTIFICATE/{n++; f=d"/served-"n".pem"} f{print > f} /END CERTIFICATE/{f=""}' "$1"
  local c
  for c in "$T"/served-*.pem; do
    openssl x509 -in "$c" -noout -subject | grep -q "CN *= *radius.kazuha.org" && { echo "$c"; return; }
  done
}
serves() {  # set-dir: does the site now present that set's certificate?
  local leaf
  rm -f "$T/served.pem"
  eap alice correct-horse "$T/served.pem" >/dev/null || true
  leaf=$(served_leaf "$T/served.pem" 2>/dev/null || true)
  [ -n "$leaf" ] && [ "$(fp "$leaf")" = "$(fp "$1/server.pem")" ]
}
stop_quick() {  # container: docker stop returns fast with exit code 0 and FreeRADIUS shut down cleanly
  local t0=$SECONDS code
  docker stop -t 15 "$1" >/dev/null
  code=$(docker inspect -f '{{.State.ExitCode}}' "$1")
  [ $((SECONDS - t0)) -le 6 ] && [ "$code" = "0" ]
}

# 1. basic login, generated configuration
site "$SYNC_PW"
if wait_log "$P-site" "Ready to process requests" 30; then ok "site starts with a pulled certificate set"
else bad "site did not start"; docker logs "$P-site" 2>&1 | tail -20; exit 1; fi
# CERT_SYNC_URL lists a dead service first (127.0.0.1:9): the set must come from the second one.
if docker logs "$P-site" 2>&1 | grep -q "cannot get the certificate set from 127.0.0.1:9 " \
   && docker logs "$P-site" 2>&1 | grep -q "got a new certificate set from 127.0.0.1:$CERT_PORT"; then
  ok "CERT_SYNC_URL fail-over: the first service is down, the set comes from the second"
else bad "CERT_SYNC_URL fail-over"; docker logs "$P-site" 2>&1 | grep wifi-radius-proxy | head -5; fi

[ "$(eap alice correct-horse)" = "SUCCESS" ] && ok "correct password accepted" || bad "correct password not accepted"
[ "$(eap alice wrong)" = "FAILURE" ] && ok "wrong password rejected" || bad "wrong password not rejected"
cfg=$(docker exec "$P-site" sh -c 'stat -c "%U:%G %a" /etc/freeradius/clients.conf /etc/freeradius/proxy.conf' | sort -u)
[ "$cfg" = "root:freerad 640" ] && ok "generated config is root:freerad 640" || bad "generated config owner/mode: $cfg"
if docker exec "$P-site" grep -q 'secret = \$ENV{AP_RADIUS_SECRET}' /etc/freeradius/clients.conf \
   && docker exec "$P-site" grep -q 'secret = \$ENV{CENTRAL_SECRET}' /etc/freeradius/proxy.conf \
   && ! docker exec "$P-site" grep -rqE "$AP_SECRET|$CENTRAL_SECRET" /etc/freeradius/clients.conf /etc/freeradius/proxy.conf; then
  ok "secrets are referenced via \$ENV and not written to the generated config"
else bad "a secret is in the generated config, or the \$ENV reference is missing"; fi
REAL_CA=$(docker run --rm --entrypoint printenv "$IMAGE" CA_SHA256)
REAL_NC=$(echo "$REAL_CA" | tr -d : | tr 'a-f' 'A-F')
if docker logs "$P-site" 2>&1 | grep -q "WARNING: CA_SHA256 is overridden" \
   && docker logs "$P-site" 2>&1 | grep -q "built-in: $REAL_NC" \
   && docker logs "$P-site" 2>&1 | grep -q "in use:   $(echo "$CA_FP" | tr 'a-f' 'A-F')"; then
  ok "an overridden CA_SHA256 logs a warning naming both fingerprints"
else bad "no warning for the overridden CA_SHA256"; fi
if ! docker logs "$P-site" 2>&1 | grep -qE "$AP_SECRET|$CENTRAL_SECRET|$SYNC_PW"; then ok "no secret in the log"
else bad "a secret appears in the log"; fi

# 2. rotation
publish "$T/set2"
if [ "$(timeout 30 docker wait "$P-site")" = "0" ] && docker logs "$P-site" 2>&1 | grep -q "restarting to load it"; then
  ok "new certificate set makes the container exit cleanly"
else bad "container did not exit after a new certificate set"; fi
docker rm -f "$P-site" >/dev/null
site "$SYNC_PW"
wait_log "$P-site" "Ready to process requests" 30 || bad "site did not restart"
serves "$T/set2" && ok "after restart the new certificate is served" || bad "the new certificate is not served"
docker exec "$P-site" test -s /var/lib/cert-sync/previous/server.pem \
  && cmp -s <(docker exec "$P-site" cat /var/lib/cert-sync/previous/server.pem) "$T/set1/server.pem" \
  && ok "the replaced set is kept in previous/" || bad "previous/ does not hold the replaced set"
docker rm -f "$P-site" >/dev/null

# 3. wrong account on a fresh site
docker volume rm "$P-cache" >/dev/null
site "not-the-password"
if wait_log "$P-site" "no valid certificate set yet" 15 && ! docker logs "$P-site" 2>&1 | grep -q "Ready to process requests"; then
  ok "wrong account: site waits and does not run"
else bad "wrong account: unexpected behaviour"; fi
docker logs "$P-site" 2>&1 | grep -q "401" && ok "the refusal (401) is logged" || bad "401 not logged"
stop_quick "$P-site" && ok "docker stop during the first-start wait is quick and exits 0" || bad "docker stop during the wait was slow or not clean"
docker rm -f "$P-site" >/dev/null

# 4. fail-over: the first central server (127.0.0.2) has nothing listening
docker volume rm "$P-cache" >/dev/null
site "$SYNC_PW" "CENTRAL_SERVERS=127.0.0.2:$CENTRAL_PORT,127.0.0.1:$CENTRAL_PORT"
wait_log "$P-site" "Ready to process requests" 30 || bad "site (two central servers) did not start"
# With the shipped tuning (response_window 15 s), the first login that reaches the dead server waits
# for the window to pass, then fails; FreeRADIUS marks that server zombie and every later login goes
# to the next one. So: one login may fail while the dead server is discovered, the next must succeed.
eap alice correct-horse >/dev/null || true
[ "$(eap alice correct-horse)" = "SUCCESS" ] && ok "first central down: after it is detected, logins work through the second" \
  || bad "first central down: login still failing"
docker rm -f "$P-site" >/dev/null

# 5. a CA that is not the pinned one (the image's own pin cannot match a throwaway CA)
docker volume rm "$P-cache" >/dev/null
site "$SYNC_PW" "CA_SHA256=<default>"
if wait_log "$P-site" "does not match the pinned CA_SHA256" 20 && wait_log "$P-site" "no valid certificate set yet" 5 \
   && ! docker logs "$P-site" 2>&1 | grep -q "Ready to process requests"; then
  ok "set with a non-matching CA is rejected; the fresh site keeps waiting"
else bad "non-matching CA: unexpected behaviour"; docker logs "$P-site" 2>&1 | tail -5; fi
docker logs "$P-site" 2>&1 | grep -q "WARNING: CA_SHA256" && bad "a warning was logged although CA_SHA256 is the image's own" \
  || ok "no CA_SHA256 warning when the image's own pin is used"
docker rm -f "$P-site" >/dev/null

# 6. a set that FreeRADIUS refuses is not adopted
docker volume rm "$P-cache" >/dev/null
publish "$T/set1"
site "$SYNC_PW"
wait_log "$P-site" "Ready to process requests" 30 || bad "site did not start for the refused-set case"
publish "$T/weak"
if wait_log "$P-site" "was rejected: FreeRADIUS cannot load it" 25; then
  ok "a set that passes the checks but that FreeRADIUS refuses is rejected"
else bad "the FreeRADIUS-refused set was not rejected"; docker logs "$P-site" 2>&1 | tail -10; fi
if [ "$(docker inspect -f '{{.State.Running}}' "$P-site")" = "true" ] \
   && ! docker logs "$P-site" 2>&1 | grep -q "restarting to load it" && serves "$T/set1"; then
  ok "the previous set stays live"
else bad "the live set changed or the site stopped"; fi
stop_quick "$P-site" && ok "docker stop on the running site is quick and exits 0" || bad "docker stop on the running site was slow or not clean"
if docker logs "$P-site" 2>&1 | grep -q "Exiting normally"; then ok "FreeRADIUS shut down cleanly on TERM"; else bad "FreeRADIUS did not log a clean exit"; docker logs "$P-site" 2>&1 | tail -12; fi
docker rm -f "$P-site" >/dev/null

# seed_cache CURRENT_DIR PREVIOUS_DIR: fill the (empty) cache volume with a current and a previous set
seed_cache() {
  rm -rf "$T/seed"; mkdir -p "$T/seed/cur" "$T/seed/prev"
  cp "$1"/{server.pem,server.key,ca.pem} "$T/seed/cur/"; cp "$2"/{server.pem,server.key,ca.pem} "$T/seed/prev/"
  local d
  for d in cur prev; do (cd "$T/seed/$d" && sha256sum server.pem server.key ca.pem > SHA256SUMS); done
  chmod -R a+rX "$T/seed"
  docker run --name "$P-seed" --rm --entrypoint sh -v "$P-cache:/c" -v "$T/seed:/seed:ro" "$IMAGE" -c \
    'cp /seed/cur/* /c/ && mkdir /c/previous && cp /seed/prev/* /c/previous/' >/dev/null
}

# 7. boot fall-back: the cached current set is unloadable, previous/ is good, the service unreachable
docker volume rm "$P-cache" >/dev/null
seed_cache "$T/weak" "$T/set2"
site "not-the-password"
if wait_log "$P-site" "Ready to process requests" 30 && docker logs "$P-site" 2>&1 | grep -q "running on the PREVIOUS set" && serves "$T/set2"; then
  ok "boot falls back to previous/ when the current cached set is unusable"
else bad "boot fall-back did not work"; docker logs "$P-site" 2>&1 | tail -10; fi
docker rm -f "$P-site" >/dev/null

# 8. rotating an unloadable current set must not overwrite a good previous/
docker volume rm "$P-cache" >/dev/null
seed_cache "$T/weak" "$T/set1"
publish "$T/set2"
site "$SYNC_PW"
if wait_log "$P-site" "Ready to process requests" 30 && docker logs "$P-site" 2>&1 | grep -q "keeping the existing previous/" \
   && serves "$T/set2" \
   && cmp -s <(docker exec "$P-site" cat /var/lib/cert-sync/previous/server.pem) "$T/set1/server.pem"; then
  ok "a broken current set did not overwrite the good previous/"
else bad "previous/ was overwritten or the new set was not adopted"; docker logs "$P-site" 2>&1 | tail -10; fi
docker rm -f "$P-site" >/dev/null

# 9. a leaf issued through an intermediate
docker volume rm "$P-cache" >/dev/null
mkdir -p "$T/chain"; issue_chain "$T/chain"; publish "$T/chain"
site "$SYNC_PW"
if wait_log "$P-site" "Ready to process requests" 30 && serves "$T/chain"; then
  ok "server.pem = leaf + intermediate is accepted and served"
else bad "chain set (leaf + intermediate) not accepted"; docker logs "$P-site" 2>&1 | tail -10; fi
docker rm -f "$P-site" >/dev/null

# 10. a CA that the image's system store trusts, but that is not the pinned CA. ca.pem is the pinned
# CA; the leaf is signed by the rogue CA. Only the system store could make that chain verify.
docker volume rm "$P-cache" >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=e2e rogue CA" -keyout "$T/rogue.key" -out "$T/rogue.pem" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
mkdir -p "$T/rogue" "$T/rogue-build"
issue "$T/rogue" 2048 "$T/rogue.pem" "$T/rogue.key"; cp "$T/pki/ca.pem" "$T/rogue/ca.pem"
cp "$T/rogue.pem" "$T/rogue-build/rogue.crt"
printf 'FROM %s\nCOPY --chmod=644 rogue.crt /usr/local/share/ca-certificates/rogue.crt\nRUN update-ca-certificates\n' "$IMAGE" > "$T/rogue-build/Dockerfile"
# Use the "default" builder (docker driver): it sees the image under test in the local store and
# loads the result there. In CI, setup-buildx makes a docker-container builder the default, which
# would neither see local images nor load the result.
docker buildx build --builder default --load -q -t "$P-rogue:test" "$T/rogue-build" >/dev/null
# precondition: in that image the rogue leaf does verify through the system store
docker run --rm -v "$T/rogue:/r:ro" --entrypoint openssl "$P-rogue:test" verify /r/server.pem 2>&1 | grep -q ": OK" \
  && ok "(precondition) the rogue CA is trusted by the test image's system store" || bad "(precondition) the rogue CA is not in the system store"
publish "$T/rogue"
SITE_IMAGE="$P-rogue:test" site "$SYNC_PW"
if wait_log "$P-site" "does not chain to the pinned ca.pem" 20 && ! docker logs "$P-site" 2>&1 | grep -q "Ready to process requests"; then
  ok "a leaf from a CA in the system trust store (not the pinned CA) is rejected"
else bad "a leaf from a system-trusted rogue CA was not rejected"; docker logs "$P-site" 2>&1 | tail -5; fi
docker rm -f "$P-site" >/dev/null

# 11. a SHA256SUMS naming an extra path (sha256sum -c would open /dev/zero and hang)
docker volume rm "$P-cache" >/dev/null
publish "$T/set1"
printf '%064d  /dev/zero\n' 0 >> "$T/dist/SHA256SUMS"
site "$SYNC_PW"
if wait_log "$P-site" "SHA256SUMS must be exactly three lines" 10 && ! docker logs "$P-site" 2>&1 | grep -q "Ready to process requests"; then
  ok "a SHA256SUMS with an extra /dev/zero line is rejected quickly"
else bad "extra line in SHA256SUMS: not rejected quickly"; docker logs "$P-site" 2>&1 | tail -5; fi
docker rm -f "$P-site" >/dev/null
publish "$T/set1"

# 12. invalid .env items
secret_marker=Sup3rS3cretValue
out=$(docker run --rm --name "$P-env" \
  -e SITE_NAME=Bad_Name -e AP_SUBNETS=10.0.0.0/33,300.1.1.1 -e AP_RADIUS_SECRET="${secret_marker}\"x" \
  -e CENTRAL_SERVERS=192.0.2.1:70000 -e CENTRAL_SECRET="a\$b{c}#d${secret_marker}" \
  -e CERT_SYNC_URL=http://192.0.2.1:80,https://192.0.2.1:80/x -e CERT_SYNC_USER=u -e CERT_SYNC_PASSWORD=p \
  "$IMAGE" 2>&1) && rc=0 || rc=$?
missing_all=""
for v in SITE_NAME AP_SUBNETS AP_RADIUS_SECRET CENTRAL_SERVERS CENTRAL_SECRET CERT_SYNC_URL; do
  echo "$out" | grep -q "invalid setting: $v" || missing_all="$missing_all $v"
done
[ "$rc" = "1" ] && [ -z "$missing_all" ] && ok "invalid .env: exit 1, every bad item named" || bad "invalid .env: rc=$rc, not named:$missing_all"
echo "$out" | grep -q "$secret_marker" && bad "invalid .env: a secret value was printed" || ok "invalid .env: no secret value in the message"
out=$(docker run --rm --name "$P-env" -e SITE_NAME=x "$IMAGE" 2>&1) && rc=0 || rc=$?
[ "$rc" = "1" ] && echo "$out" | grep -q "AP_SUBNETS" && ok "missing variables: exit 1 with a clear message" || bad "missing variables: rc=$rc"

# AP_SUBNETS policy: a /7, 0.0.0.0/x and (without the test knob) loopback are refused
out=$(docker run --rm --name "$P-env" -e SITE_NAME=x -e AP_SUBNETS=10.0.0.0/7,0.0.0.0/0,127.0.0.1,192.168.1.0/24 \
  -e AP_RADIUS_SECRET=a -e CENTRAL_SERVERS=192.0.2.1:1812 -e CENTRAL_SECRET=b \
  -e CERT_SYNC_URL=http://192.0.2.1:80 -e CERT_SYNC_USER=u -e CERT_SYNC_PASSWORD=p "$IMAGE" 2>&1) && rc=0 || rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q "10.0.0.0/7 .*shorter than /8" && echo "$out" | grep -q "0.0.0.0/0 .*every address" \
   && echo "$out" | grep -q "127.0.0.1 .*ALLOW_LOOPBACK_AP" && ! echo "$out" | grep -q "192.168.1.0/24"; then
  ok "AP_SUBNETS: /7, 0.0.0.0/x and loopback are refused with a reason; a normal subnet is not"
else bad "AP_SUBNETS policy: rc=$rc"; echo "$out"; fi

echo "e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
