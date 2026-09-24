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
| `MY_OMARCHY_BASE_URL` / `MY_OMARCHY_HOST` | My Omarchy (`docs/my-omarchy.md`): the hostname the hub answers on and generates links for (default `https://my.omarchy.org`). Both hosts point at this one app; `/my/*` also answers on the registry host. |
| `SESSION_COOKIE_DOMAIN` | Set to `omarchy.org` so one sign-in covers plugins. and my. (session + CSRF cookies scoped to the parent domain). Unset = host-only cookies, sign in on each host separately. |
| `PASSKEY_RP_ID` | Set to `omarchy.org` **before launch** so one passkey works on both hosts. Unset, passkeys work only on the registry host. Changing it later invalidates every enrolled passkey. |
| `OPENROUTER_MANAGEMENT_KEY_FILE` (or `OPENROUTER_MANAGEMENT_KEY`) | Enables voice keys. A *management* key from openrouter.ai/settings/management-keys (it can only mint/manage other keys). Keep it in a file on a read-only bind mount like the AI-review credentials, give it an expiry at the provider, and keep Auto Top-Up on the account: every voice key draws from the same balance. Unset = voice is off. |
| `VOICE_MONTHLY_LIMIT_USD` / `VOICE_KEY_TTL_DAYS` / `VOICE_MAX_ACTIVE_KEYS` / `VOICE_MODEL` | Per-key monthly cap (5), key lifetime (90), global live-key cap (2000) — cap × keys is the worst-case monthly exposure — and the transcription model handed to clients (`openai/whisper-1`). |
| `AI_REVIEW_COMMAND` | Optional — enables LLM review in the pipeline (escalate-only). The command runs with a scrubbed environment (no app secrets); it should call a REMOTE model API with its own credentials, and for full isolation run it under a separate UID (systemd DynamicUser or a sidecar). Note the adapter receives UNPUBLISHED submissions and previous source — treat its endpoint as a confidential-data processor. |

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

## My Omarchy (my.omarchy.org)

Same container, second hostname. Add `my.omarchy.org` to the tunnel's
ingress (→ the same `kamal-proxy`), to `proxy.host` (Kamal accepts a list),
and set the four variables above. Storage: dotfile bundles and snaps are
Active Storage blobs, so they land in R2 next to the tarballs. Voice needs
the management key file at `/ai/openrouter_management_key` (or wherever
`OPENROUTER_MANAGEMENT_KEY_FILE` points).

## Day-2 controls

- Admin queue: `/admin` (quarantined/held versions, reports — including
  reported snaps — recent snaps with one-click Hide, kill list).
- `bin/rails registry:regenerate` rebuilds the whole data plane from the DB.
- Publish hold window: off by default (`PUBLISH_HOLD_SECONDS`, 0). Set it to
  a number of seconds during an incident to delay review-clean versions going
  live; the security gates are the deterministic scan + AI review, with
  per-plugin submission quotas (5 pending, 12/day) throttling abuse.
