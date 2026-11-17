# wifi-proxy

The Docker version of the Kazuha Hub Wi-Fi proxy: one container image, the same for every site.
(The OPNsense version is the plugin `os-kazuhahub-wifi-proxy`.)

```
AP / AC --EAP-TTLS--> this container --inner PAP over a private network--> central FreeRADIUS --> Entra ID
          (LAN, UDP 1812)  terminates TLS     (fail-over: primary, then backups)
```

- Based on the official `freeradius/freeradius-server:latest-3.2` image. It stays on 3.2 on purpose:
  FreeRADIUS 4 changes the configuration format. The [upstream watch](.github/workflows/upstream-watch.yml)
  opens an issue when a 4.x release appears.
- No certificates, keys or secrets are in the repository or the image. The certificate set
  (`server.pem`, `server.key`, `ca.pem`) is pulled from the central certificate service at start and
  every 6 hours, with the site's own account.
- The CA is pinned. The fingerprint of the CA certificate is built into the image (`CA_SHA256` in the
  [Dockerfile](Dockerfile)); a pulled set is used only if its `ca.pem` has exactly that SHA-256
  fingerprint. The service is reached over plain HTTP on a private network, so the channel is not
  what is trusted: without the pin, whoever could answer that request could give a site a CA and
  certificate of their own. A change of CA is therefore a reviewed commit and a new image.
- A set is used only if it verifies: `SHA256SUMS` is exactly three lines for `server.pem`, `server.key`
  and `ca.pem`, and the files match it; `ca.pem` is one certificate and the pinned one; the certificate
  (`server.pem` may be the leaf followed by intermediates) chains to that CA alone, with the system
  trust store switched off, is not expired, has `radius.kazuha.org` as an exact subjectAltName DNS entry,
  and matches the key; and FreeRADIUS really loads it (checked with `freeradius -C` on a temporary copy
  before anything is replaced).
- A new set makes the container exit so Docker restarts it on the new set. The replaced set is kept as
  `previous/` in the cache volume, but only if FreeRADIUS loads it (a broken set never overwrites a good
  `previous/`). If FreeRADIUS cannot start on the current set at boot, the container falls
  back to `previous/` once and logs it loudly. The cache also keeps the site working while the
  certificate service is away.
- `docker stop` is handled at any time (also while waiting for the first set); FreeRADIUS is shut down
  cleanly.

## Deploying a site

The host must be able to reach the central servers and the certificate service (a private network or VPN).

1. On the certificate service, give the site an account (user and password).
2. On the site, put two files in one folder:
   - [`compose.yaml`](compose.yaml), unchanged
   - `.env`, from [`.env.example`](.env.example), with all 8 variables:

     | Variable | Meaning |
     |---|---|
     | `SITE_NAME` | short name for logs; 1-32 characters of `a-z`, `0-9`, `-` |
     | `AP_SUBNETS` | comma-separated IPv4 addresses or CIDRs the APs send from, one or more; prefixes shorter than /8, `0.x` addresses and loopback are refused |
     | `AP_RADIUS_SECRET` | one shared secret for all AP subnets |
     | `CENTRAL_SERVERS` | comma-separated `IPv4:port`, one or more, in fail-over order (first = primary) |
     | `CENTRAL_SECRET` | shared secret with the central servers |
     | `CERT_SYNC_URL` | `http://IPv4:port` of the certificate service (plain http, no path) |
     | `CERT_SYNC_USER` | this site's account for the certificate service |
     | `CERT_SYNC_PASSWORD` | its password |

3. Start it (`docker compose up -d`, or create a project from the folder in the NAS UI).
   The log shows the certificate set it got and `Ready to process requests`.
4. Point the AP / AC at the host's LAN address, port 1812, with `AP_RADIUS_SECRET`.

Every variable is required and has no default. At start each one is checked strictly (IPv4 octets
0-255, prefix 0-32, port 1-65535, the `SITE_NAME` characters) and the container exits with status 1,
naming every bad item. The secrets must not contain `"`, `\`, `$`, `{`, `}`, `#` or a newline: those
characters are special in FreeRADIUS configuration or in `.env` files and could break parsing or
quoting. `openssl rand -hex 16` gives a safe secret.

`clients.conf` and `proxy.conf` are generated at start from these lists: one `client` per AP subnet
(`site-lan-1`, `site-lan-2`, ...), one `home_server` per central server in a fail-over pool, and the realm
`ENTRA`. The secrets are written as `$ENV{...}` references, never as values, so no file holds them.
When the primary central server stops answering, the first login that reaches it waits out the
response window (15 s) and fails; after that the server is marked dead and logins go to the next one.

Optional settings exist for tests and tuning only; leave them out normally: `CERT_SYNC_INTERVAL`
(seconds between checks, default 21600), `LISTEN_PORT` (default 1812), `ALLOW_LOOPBACK_AP=1` (accept
127.x in `AP_SUBNETS`) and `CA_SHA256` (replace the pinned CA; the container then logs a WARNING at
every start naming the in-use and the built-in fingerprint).

Updating: pull the new image and recreate the container. Nothing else changes on the site.

## Image

`ghcr.io/kazuhahub/wifi-proxy`, for linux/amd64 and linux/arm64, signed with cosign (keyless) and
with build provenance. Tags: `3.2` (what sites use), `latest`, `sha-<commit>`.
Sites pull it through the registry mirror: `ghcr.docker.kazuhahub.com/kazuhahub/wifi-proxy:3.2`.

[`image.yml`](.github/workflows/image.yml) runs [`test/e2e.sh`](test/e2e.sh) (a real EAP-TTLS login
against a throwaway CA, certificate service and central, plus certificate rotation, fail-over, a refused
account, a wrong CA, a set FreeRADIUS refuses, boot fall-back and bad `.env` items). On a pull request it builds and
tests for amd64. On `main` it builds amd64 and arm64 once, tests the amd64 variant of that build,
and only then tags those same digests and signs them. The arm64 variant is built but not run in CI.
There is no scheduled rebuild: the image is rebuilt on a push to `main` or a manual run, which also
picks up a newer official 3.2 base.

## Security notes

- The certificate service is plain HTTP and relies on the private network (WireGuard) for
  confidentiality. The site account is shared by all sites by design.
- What makes a set trustworthy is the checks, above all the pinned CA, not the channel.
- A replayed older-but-valid set is accepted by design. After a key rotation on the central side,
  revoke the old site accounts too if a leak is suspected.
- Downloaded files are kept in a scratch directory that is removed on `docker stop` and emptied at every
  start; secrets are never written to a file or logged.

## Upstream watch

[`upstream-watch.yml`](.github/workflows/upstream-watch.yml) runs weekly and opens one issue when
FreeRADIUS 4 appears. Failures of its web requests fail the job. GitHub disables scheduled workflows
after 60 days without repository activity, so if the repository is quiet for that long the watch stops;
the workflow's run history in the Actions tab shows when it last ran. No keepalive is used.

## Layout

| Path | What |
|---|---|
| `Dockerfile` | the image; bakes in the pinned CA fingerprint (`CA_SHA256`) |
| `wifi-proxy.sh` | entrypoint: validates `.env`, generates `clients.conf` and `proxy.conf`, gets and verifies the certificate set, runs FreeRADIUS |
| `raddb/` | static FreeRADIUS configuration: EAP-TTLS module and the two virtual servers |
| `compose.yaml`, `.env.example` | what a site deploys |
| `test/e2e.sh` | end-to-end test used by CI; runs on any Docker host with `eapol_test` |
| `.github/workflows/` | image build, test and publish; weekly FreeRADIUS 4 watch |
