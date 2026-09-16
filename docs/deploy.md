# Deploying plugins.omarchy.org

One Rails app (control plane) + a directory of static files (data plane) synced
to object storage behind a CDN. Installs never touch Rails.

## Kamal (the supported path)

`config/deploy.yml` deploys web + jobs to a single host. Current target is the
E2E staging box `omarchy-plugins` (Proxmox, Debian 13), reached over Tailscale:

- **TLS**: terminated at the Cloudflare edge. The tunnel is the encrypted
  transport to the VM and hands requests to kamal-proxy over the private
  docker network as plain HTTP (`proxy.ssl: false`; `config.assume_ssl` keeps
  Rails treating them as https). No origin certificate exists to renew.
- **Image registry**: self-hosted `registry:2` on the VM (htpasswd user
  `kamal`, password in `.kamal/local/registry_password`, data under
  `/opt/registry`). Internal deploy plumbing only — it's the one remaining
  tailscale-FQDN name and carries the one remaining cert (renew ~90 days:
  `tailscale cert` on the VM, copy to `/opt/registry/certs/`,
  `docker restart registry`); swap to ghcr.io/omacom-io when an org PAT
  with write:packages exists.
- **Public ingress**: a Cloudflare Tunnel accessory (`cloudflared`) serves
  `omarchy-plugins.ryanhughes.me` — the canonical `REGISTRY_BASE_URL` and the
  ONLY hostname the app answers to. Tunnel is remotely managed (ingress
  config in the Cloudflare dashboard, token in `.kamal/local/tunnel_token`);
  DNS is a proxied CNAME `omarchy-plugins` →
  `3fe84e30-e646-43e0-8352-4e1bb474b152.cfargotunnel.com`. Passkeys bind to
  the canonical host — enroll them on the public domain.
- **Mail**: a Mailpit accessory catches login-code email — web UI at
  `http://omarchy-plugins:8025`. Swap the `SMTP_*` env for a real provider
  before launch.
- **Secrets**: everything `.kamal/secrets` reads lives git-ignored in
  `.kamal/local/` (TLS cert/key, `signing_seed`, `registry_password`) —
  back that directory up; the signing seed especially (custody note below).

```sh
bin/kamal setup                                            # first deploy
bin/kamal app exec 'bin/rails registry:grant_admin[you@omarchy.org]'
bin/kamal deploy                                           # every deploy after
```

`bin/kamal console` / `logs` / `shell` / `dbc` are aliased. The config mounts
`omarchy_registry_storage` at `/rails/storage` (databases + data plane — the
volume the rest of this document is about) and a separate
`omarchy_registry_witness` volume for `REGISTRY_WITNESS_PATH` (ideally backed
by a second disk so an app-volume restore can't also roll back the witness —
not possible on the current single-volume staging box; revisit for
production). Production cutover to plugins.omarchy.org: swap `proxy.host`,
the `REGISTRY_*`/`SMTP_*` env, `ssl: true` (needs public 80/443), and the
image registry. The sections below describe what the deploy must provide and
apply to any orchestration.

## Required environment

| Variable | Purpose |
|---|---|
| `SECRET_KEY_BASE` | Rails secrets (also derives the device-flow token encryptor) |
| `REGISTRY_SIGNING_SEED` | Base64 32-byte Ed25519 seed — signs every index file and the kill list. Generate: `ruby -red25519 -rbase64 -e 'puts Base64.strict_encode64(Ed25519::SigningKey.generate.seed)'`. **Custody per the governance page; losing it means re-pinning every client.** |
| `REGISTRY_BASE_URL` | `https://plugins.omarchy.org` |
| `REGISTRY_PREVIOUS_SIGNING_PUBKEY` | Rotation only: the OLD base64 public key. **Rotation is a coordinated incompatible event** — deployed clients pin one key and fail closed until they re-pin. A key swap requires `REGISTRY_ALLOW_KEY_ROTATION=1`, this variable matching the on-disk trust root (so every surviving signed file keeps verifying fail-closed), **and** `REGISTRY_ROTATION_ACK=clients-must-repin` acknowledging the client impact. Remove all three after the first post-rotation regeneration. |
| `REGISTRY_WITNESS_PATH` | Strongly recommended: a file on storage SEPARATE from the app volume (second disk, object-store mount). Each regeneration records the signed kill-list generation there; after a full-volume restore the witness proves the data plane is older than the last published kill list and regeneration refuses to sign a newer empty one until `registry:import_revocations` restores the authoritative copy (`REGISTRY_RESTORE_ACK=1` overrides once, deliberately). Unset = a full-volume restore to a pre-revocation state is locally undetectable. |
| `REGISTRY_HOST` | Host-authorization allowlist (defaults to `plugins.omarchy.org`). Requests carrying any other `Host` are rejected — session cookies are never minted for attacker-pointed domains. `ADDITIONAL_HOSTS` (comma-separated) adds extras; `/up` is exempt for by-IP health checks. |
| `SMTP_ADDRESS` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | Login-code email delivery |
| `AI_REVIEW_COMMAND` | Optional advisory LLM review. Production accepts only `/rails/script/ai_review_adapter` and always runs it in the processor sandbox. Missing configuration, incomplete coverage, malformed results or sandbox/provider failure quarantine the version. The endpoint receives UNPUBLISHED source — treat it as a confidential-data processor. |

## Processor isolation: deployment prerequisite

The supported boundary is **dedicated processor containers**, configured in
`deploy/processors.compose.yml`. Docker's normal seccomp policy remains enabled:
no privileged containers, added capabilities, Docker socket mounts, nested
Bubblewrap, or host namespace-policy changes.

```text
Rails ── Unix socket ── media processor (no network)
      └─ Unix socket ── AI processor ── isolated bridge ── provider gateway ── model
```

Processor images contain only fixed scripts/libraries, dependencies and (for
media) bundled fonts. They contain no Rails app and mount no app configuration,
storage, signing keys or witness. They run non-root with dropped capabilities,
read-only root filesystems, private PID namespaces, bounded CPU/memory/processes
and temporary storage, and no core dumps. Rails mounts only the socket volumes,
read-only. Requests accept fixed operations with byte/time limits, never commands
or paths. Socket volumes are 1MB tmpfs mounts, not unbounded host-disk storage.
Each operation starts a scrubbed, bounded child. Automatic Active
Storage analyzers/previewers are disabled so Rails never decodes images again.

Media uses `network_mode: none`. AI has only an internal bridge in **isolated
gateway mode**, without a host address/default route or external DNS forwarding.
Its only peer is the provider gateway; it is not on the Rails/Kamal network.
Plain `internal: true` is insufficient: it can still expose services listening
on the host's bridge address. Docker must support isolated gateway mode; the
supplied configuration and inspection checks were tested on Docker 29.7.2.

Only the gateway mounts `/opt/registry-ai` at `/ai:ro` and has outbound networking.
It is a fixed-destination JSON relay, not a general proxy. Only the configured
model's completion endpoint is accepted; client URL/auth headers are ignored,
redirects and tool-bearing requests are refused, and input/output sizes are
bounded. Provider keys never reach Rails or the AI processor. Hosted endpoints
require verified HTTPS. A trusted local vLLM HTTP endpoint needs explicit
`REGISTRY_ALLOW_HTTP_MODEL=1`; this permits HTTP only to the operator-configured
destination, never a request-selected address. The endpoint receives unpublished
submissions as its intended job.

Containers still share a kernel: keep Docker, the host and decoders patched.
The gateway is trusted egress code; compromising the gateway itself is outside
its destination restriction. AI prompts and passing scans are not proofs of
package safety. Development/test still use local scrubbed subprocesses, not
production isolation; never accept hostile uploads there.

### Rollout order

1. Build the Dockerfile targets `processor-ai`, `processor-media` and
   `provider-gateway` from the same reviewed revision as Rails. Use immutable
   `REGISTRY_PROCESSOR_IMAGE_PREFIX` / `REGISTRY_PROCESSOR_TAG` image names, or
   build from that trusted checkout on the host. Do not use floating tags.
2. Prepare the existing provider directory without printing its contents.
   Gateway UID 1001/GID 1000 needs read access; restrict files to that
   operator-controlled group. It supports `openai_key` or `anthropic_key`,
   optional `base_url`, `model`, `effort`, and `chunk_chars` (1024–120000).
   No app keys belong there. Set `REGISTRY_ALLOW_HTTP_MODEL=1` only for a
   deliberately selected trusted HTTP model server.
3. Start processors on the app host and inspect their actual Docker policy:

   ```sh
   export REGISTRY_PROCESSOR_TAG=REVIEWED_REVISION
   docker compose -f deploy/processors.compose.yml up -d --build
   ruby script/check_processor_containers
   ```

   For prebuilt images, set `REGISTRY_PROCESSOR_IMAGE_PREFIX`, pull, and use
   `up -d --no-build`. The read-only audit needs Ruby and Docker CLI on PATH;
   it can run from an authorized workstation using
   `DOCKER_HOST=ssh://root@omarchy-plugins`. It never reads credentials or
   executes submitted code. Keep the default production socket-volume names
   used in `config/deploy.yml`.
4. Run the app image preflight with only those sockets attached:

   ```sh
   docker run --rm --network none \
     -v omarchy_registry_processor_ai:/run/registry-processors/ai:ro \
     -v omarchy_registry_processor_media:/run/registry-processors/media:ro \
     --entrypoint /rails/script/check_processor_sandbox APP_IMAGE
   ```

   It checks service/protocol readiness (including gateway configuration) and
   renders synthetic images without a model request. It does not replace the
   Docker-policy audit. Both checks must exit zero before deploying Rails.
5. Deploy Rails normally. Its web/job entrypoint repeats preflight before
   migrations/startup. The new Kamal configuration removes `/ai` from Rails
   and mounts the two processor socket volumes. Keep the old app running until
   the new one is healthy. For later processor upgrades, drain active reviews
   first: replacing a processor mid-request quarantines that request, never
   manufactures a pass. Keep previous processor images for rollback, and never
   remove socket volumes during app deployment.

Unavailable processors refuse startup or fail the operation closed: AI results
quarantine, preview uploads are refused, social cards return 503. No in-app
fallback exists. Health checks use a separate socket/thread so a long AI review
does not prevent a new app container from checking readiness.

For local testing, layer `deploy/processors.test.compose.yml` over the base file
with a separate project and `REGISTRY_PROCESSOR_VOLUME_PREFIX`. It supplies a
synthetic model on another isolated network, with no provider secrets or external
requests. Never use that overlay in a real deployment.

`.kamal/`, local environment files and Rails keys are excluded from Docker
contexts as well as Git. Ordinary Kamal builds use a clean Git clone; direct
workspace builds rely on `.dockerignore`. No deployed secret exposure was
established by the missing exclusion alone.

## Pieces

1. **Web**: `bin/thrust bin/rails server` (Dockerfile is ready). SQLite lives
   under `/rails/storage` — you MUST mount a persistent volume there
   (`docker run -v registry-storage:/rails/storage …`), or replacing the
   container loses accounts, ownership, audit, and revocation state. The same
   mount also persists the data plane. To move to Postgres instead, add
   `gem "pg"` and point `production.primary` at `DATABASE_URL`.
2. **Jobs**: `bin/jobs` (Solid Queue) — runs the review pipeline, hold-window
   releases, and index regeneration. Required.
3. **Data plane**: `storage/data_plane/` is the CDN origin. Either serve the
   Rails routes (`/index`, `/dl`, `/revocations.json`, `*.sig`, …) behind the
   CDN, or sync the directory to object storage and point the CDN there.
   Sync index files with `--delete`; sync `/dl/` WITHOUT `--delete` (tarballs
   are immutable, and `registry:regenerate` re-freezes any missing ones from
   Active Storage — note those blobs live on the SAME `/rails/storage` volume
   by default, so back that volume up as one unit, or point Active Storage at
   object storage so uploads survive volume loss independently). Keep TTLs
   short (~60 s) on index files and long on `/dl/`.
   The kill list is additionally self-healing: regeneration merges the signed
   on-disk `revocations.json` back into the database, so a database restored
   from a pre-revocation backup cannot silently revive revoked malware.
4. **Domains**: `plugins.omarchy.org` → app/CDN; `omarchyplugins.com` → 301.

## First boot

```sh
bin/rails db:prepare
bin/rails registry:grant_admin[you@omarchy.org]   # admin bootstrap — required before any takedown control works
```

The new admin signs in (email code), enrolls a passkey or TOTP, and `/admin`
unlocks. Every containment control requires an admin with a verified second
factor.

## Seeding day

```sh
bin/rails registry:seed_catalog[catalog.json]   # catalog from omarchyplugins.com listing
bin/rails registry:process_reviews              # or let bin/jobs drain the queue
```

Then notify listed authors to claim: each publisher page shows the
repo-proof claim flow. Seeded plugins that failed the pipeline stay visible as
under-review and uninstallable.

## Day-2 controls

- Admin queue: `/admin` (quarantined/held versions, reports, kill list).
- `bin/rails registry:regenerate` rebuilds the whole data plane from the DB.
- Publish hold window: off by default (`PUBLISH_HOLD_SECONDS`, 0). Set it to
  a number of seconds during an incident to delay review-clean versions going
  live; deterministic scans, advisory AI, required human review and per-plugin
  submission quotas (5 pending, 12/day) provide separate controls.

First executable releases always need human review, even with a passing AI
result. Every version with dynamic execution/network call sites needs human
judgment too. Constrained declarative themes can clear automatically with all
checks complete. Test/doc filenames and legacy verification are not exemptions;
uncertain or incomplete scans remain quarantined. Human approvals and takedowns
are serialized with release state changes, and approved versions enter the same
configured hold window before release.
