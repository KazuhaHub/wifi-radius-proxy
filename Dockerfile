# Wi-Fi RADIUS site proxy: the official FreeRADIUS 3.2 image plus the site configuration and an
# entrypoint that keeps the certificate set in step with the central service. See README.md.
# The base stays on the 3.2 line on purpose: FreeRADIUS 4 has a different configuration format
# (no proxy.conf), so moving to it is a deliberate migration, tracked by .github/workflows/upstream-watch.yml.
ARG BASE_IMAGE=freeradius/freeradius-server:latest-3.2
FROM ${BASE_IMAGE}

ARG REVISION=unknown

# SHA-256 fingerprint of the CA certificate that must have issued the RADIUS server certificate.
# This is the trust anchor of the whole design: the entrypoint accepts a pulled certificate set only
# if its ca.pem has exactly this fingerprint. Without the pin, anyone who could answer the plain-HTTP
# certificate request (or who got hold of the sync account) could hand a site a CA of their own and
# a matching certificate, and the site would present it to Wi-Fi clients as the RADIUS server.
# The value is public (it is the fingerprint of a public CA certificate). It is baked in here so
# that a change of CA is a reviewed commit and a new image, not a setting on each site. It can be
# overridden at run time with `-e CA_SHA256=...` (test/e2e.sh does that for its throwaway CA), but
# the entrypoint then logs a loud warning at every start. For that comparison the build-time
# value is also written to a file, which a run-time environment variable cannot change.
ARG CA_SHA256=26:DC:20:91:BE:86:84:E5:BA:30:9C:A0:13:00:B2:9B:DC:61:8B:4F:C4:B5:4B:EF:31:25:94:09:D9:E1:04:46
ENV CA_SHA256=${CA_SHA256}
RUN mkdir -p /usr/local/share/wifi-proxy \
 && printf '%s\n' "${CA_SHA256}" > /usr/local/share/wifi-proxy/ca-sha256 \
 && chmod 644 /usr/local/share/wifi-proxy/ca-sha256

LABEL org.opencontainers.image.title="wifi-proxy" \
      org.opencontainers.image.description="Kazuha Hub Wi-Fi RADIUS site proxy (EAP-TTLS, inner PAP to the central servers)" \
      org.opencontainers.image.source="https://github.com/KazuhaHub/wifi-proxy" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.revision="${REVISION}"

# Static configuration: the EAP module and the two virtual servers. clients.conf and proxy.conf are
# not shipped; the entrypoint generates them at start from the site's .env (see the script).
COPY raddb/ /tmp/site-raddb/
RUN set -eux; \
    cd /etc/freeradius; \
    rm -f sites-enabled/* mods-enabled/eap; \
    cp /tmp/site-raddb/sites-enabled/* sites-enabled/; \
    cp /tmp/site-raddb/mods-enabled/eap mods-enabled/eap; \
    mkdir -p certs-site; \
    chown -R root:freerad /etc/freeradius; \
    chmod -R go-w /etc/freeradius; \
    rm -rf /tmp/site-raddb; \
    for c in bash openssl sha256sum base64 timeout; do command -v "$c"; done

COPY --chmod=755 wifi-proxy.sh /usr/local/bin/wifi-proxy

# The verified certificate set (current and previous) survives restarts and outages of the central service here.
VOLUME /var/lib/cert-sync
ENTRYPOINT ["/usr/local/bin/wifi-proxy"]
