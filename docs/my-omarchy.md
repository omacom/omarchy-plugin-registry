# My Omarchy — `my.omarchy.org`

The account side of Omarchy: the things that should follow a person from
machine to machine. Three features, one sign-in, served by the plugin
registry's Rails app on its own hostname.

| Feature | What it is | Client command |
|---|---|---|
| **Dotfile sync** | Whole-snapshot push/pull of your Omarchy configuration | `omarchy my sync push` / `pull` |
| **Snaps** | Share a screenshot from [omasnap](https://github.com/omacom/omasnap) as an unguessable link with a preview card | `omarchy my snap share` / omasnap's share button |
| **Voice** | A personal, spend-capped OpenRouter key so [voxtype](https://voxtype.io) can transcribe in the cloud | `omarchy my voice setup` / `off` |

Plus the plumbing: `omarchy my login` / `logout`, a Devices page, and admin
takedown for shared snaps.

## Why it lives in the registry app

One account, one passwordless sign-in (emailed code or passkey), one second
factor, one admin console, one audit log, one suspension switch. A person who
publishes a plugin and a person who syncs their dotfiles are the same person,
and the registry already had the hard parts: device-flow CLI login, scoped
short-lived tokens, step-up verification, a hostile-input tar reader, an
image pipeline, R2 storage, and a moderation queue. My Omarchy is a second
front door onto the same house.

The registry's own contract (signed index, kill list, browse API) is
untouched. Nothing here is an install path.

## Hostnames

| Host | Serves |
|---|---|
| `plugins.omarchy.org` | The registry, unchanged. `/my/*` also answers here (same pages) so a single-host deployment works. |
| `my.omarchy.org` | Root = the My Omarchy hub. Every registry route still resolves, which is harmless; links generated for My pages use this host. |

Configuration: `MY_OMARCHY_BASE_URL` (default `https://my.omarchy.org`),
`MY_OMARCHY_HOST` (host authorization). For a shared session across both
hosts set `SESSION_COOKIE_DOMAIN=omarchy.org`; for passkeys that work on both
set `PASSKEY_RP_ID=omarchy.org` **before** anyone enrolls (changing it later
invalidates every passkey). See [deploy.md](deploy.md).

## Tokens: two purposes, two prefixes

| Purpose | Prefix | Lifetime | Minted by | Reaches |
|---|---|---|---|---|
| `publish` | `omp_` | 7 days (90 for OIDC) | `omarchy plugin publish`, dashboard, trusted publishing | `POST /api/v1/plugins/…/versions` only |
| `account` | `oma_` | 90 days | `omarchy my login` | `/api/v1/my/*` only |

Purpose is part of authentication, not a check a controller might forget: the
My API asks for `purpose: :account` and a publish token is simply "invalid";
the publish API asks for `purpose: :publish` and an account token is invalid
there. A leaked account token cannot publish; a leaked publish token cannot
read your dotfiles. An account token also cannot change account settings,
enroll factors, or mint a voice key on its own (see Voice).

Account tokens are **devices**: they carry the hostname the CLI reported and
are listed and revoked on `/my/devices`. At most 10 live per account.

## Signing a machine in

The same RFC 8628 device flow as publishing, with `purpose=account`:

```
POST /api/v1/device/code
  purpose=account&device=<hostname>
→ 201 { device_code, user_code, purpose: "account",
        verification_uri: "https://my.omarchy.org/device", expires_in, interval }

(the human approves user_code at verification_uri — the page says
 "Connect this machine?", names the device, and spells out what the
 token can and cannot do; approval requires a fresh second factor)

POST /api/v1/device/token   device_code=…
→ 202 { error: "authorization_pending" }   (poll every `interval` s)
→ 200 { token: "oma_…", token_type: "bearer", purpose: "account",
        scope: "my.omarchy.org · <hostname>", expires_at }
```

Store the token in `~/.local/state/omarchy/my/token` (mode 0600). Then:

```
GET /api/v1/my/whoami
Authorization: Bearer oma_…
→ { schema_version: 1,
    user: { name, email_address, handle },
    device: { name, token_expires_at },
    features: { dotfiles: true, snaps: true, voice: true|false },
    urls: { web } }

DELETE /api/v1/my/device        → 204   (omarchy my logout)
```

Every `/api/v1/my/*` response is `Cache-Control: no-store`. Errors are
`{ error: "…" }` with a meaningful status: 401 bad/expired token, 403
suspended or refused, 413 too large, 422 rejected content, 429 slow down,
501 feature disabled on this server, 502 provider unavailable.

## Dotfile sync

A snapshot is the whole thing, never a merge. The client builds a `.tar.gz`
of the Omarchy-managed configuration (paths relative to `$HOME`, e.g.
`.config/omarchy/shell.json`, `.config/hypr/bindings.lua`, `.config/ghostty/…`),
pushes it, and later pulls a snapshot back, showing a diff and asking before
writing. The server keeps the newest **10** per account and purges the rest.

```
POST /api/v1/my/dotfiles
Content-Type: application/gzip
X-Omarchy-Device: <hostname>                          (optional; defaults to the token's)
X-Omarchy-Manifest: {"omarchy_version":"4.1.0","paths":[…]}   (optional JSON, ≤256KB)
<body: the tar.gz, ≤25MB; ≤5,000 entries; ≤100MB unpacked>
→ 201 { bundle: { id, created_at, device, sha256, size_bytes, file_count,
                  encryption: "plain"|"age", omarchy_version, download_url, paths: [...] } }

GET  /api/v1/my/dotfiles               → { bundles: [ …without paths… ] }   newest first
GET  /api/v1/my/dotfiles/:id           → { bundle: { …with paths… } }
GET  /api/v1/my/dotfiles/:id/download  → the bytes; X-Omarchy-Sha256, X-Omarchy-Encryption
```

**The listing is derived from the archive, never from the client's claim.**
The archive goes through the same reader as plugin tarballs
(`Registry::SafeTar`): no symlinks or hardlinks, no absolute or escaping
paths, no PAX tricks, no duplicate paths, no bytes hidden after the archive.

**Secrets are refused by path**, server-side, whatever the client excluded:
`.ssh/`, `.gnupg/`, `.aws/`, `.netrc`, `.password-store/`, keyrings, browser
profiles, `.config/gh/hosts.yml`, `.config/omarchy/agents/*.json`, anything
ending in `.pem .key .p12 .pfx .kdbx`, and `id_*` keys. The client should
exclude the same list and never even build them into the bundle.

**Encryption is the client's choice.** Push with `--encrypt` and the client
runs the tar.gz through [age](https://age-encryption.org) with a key the
user holds. The server recognises the `age-encryption.org/v1` header, stores
the bytes opaque, cannot walk them, and shows only the `paths` the client
declared in `X-Omarchy-Manifest` (still screened against the forbidden list).
`encryption: "age"` in the response tells a pulling client to decrypt first.

## Snaps

omasnap's share button (or `omarchy my snap share file.png`) posts the image
and gets a link back on the clipboard.

```
POST /api/v1/my/snaps
Content-Type: image/png | image/jpeg | image/webp
X-Omarchy-Title: <optional, ≤120 chars>
X-Omarchy-Ttl: 1h | 1d | 7d | 30d | never      (default never)
X-Omarchy-Device: <hostname>
<body: the image bytes, ≤12MB, ≤40 megapixels, not animated>
→ 201 { snap: { token, url, image_url, title, width, height, byte_size,
                content_type, views, device, expires_at, created_at } }

GET    /api/v1/my/snaps            → { snaps: [...] }   live ones, newest first
DELETE /api/v1/my/snaps/:token     → 204                (the link dies at once)
```

Bytes must be what the `Content-Type` says: magic bytes and the decoder both
have to agree, so a PNG-headed ELF is rejected, not stored. Storage is capped
at 1GB of live snaps per account.

**Public surfaces** (no sign-in; the 12-character base58 token in the URL is
the whole authorization — ~70 bits, never listed, never in the sitemap,
`X-Robots-Tag: noindex` everywhere):

| URL | What |
|---|---|
| `https://my.omarchy.org/s/<token>` | The share page: title, dimensions, the image (click to view full size), download, report |
| `/s/<token>/image` | The original bytes, inline (`?download=1` for attachment) |
| `/s/<token>/preview` | A ≤1600×1200 WebP rendition |
| `/og/s/<token>.png` | The 1200×630 link card (the screenshot on the site's ink ground) |

A snap that is expired, deleted, or taken down is a 404 on every one of
those, indistinguishable from never-existed. Owner views don't count; the
owner sees a "Manage snaps" link instead of Report.

**Moderation**: any signed-in user can Report a snap; it lands in the admin
queue beside comment reports with "Hide + resolve". Hiding takes the page and
the bytes dark immediately, writes `snap.hide` to the audit log, and the
owner's list simply stops showing it. Admins also see the most recent snaps
on the dashboard with a one-click Hide.

## Voice

Local dictation is the default and stays the default. A voice key is for a
machine too slow to run a Whisper model well: it moves transcription to
OpenRouter's `/api/v1/audio/transcriptions` under a key that is **the
user's alone, spend-capped per month, time-boxed, and revocable**.

How it is minted: the server holds an OpenRouter **management** key (it can
create and manage other keys, it cannot call a model). Minting calls the
management API to create a key with `limit` = the monthly cap (default $5,
`VOICE_MONTHLY_LIMIT_USD`), `limit_reset: monthly` (re-arms at 00:00 UTC on
the 1st), and `expires_at` = now + `VOICE_KEY_TTL_DAYS` (default 90). The
secret is stored encrypted so a second machine can fetch it. One live key per
account: rotating deletes the old one at the provider first. Revocation
deletes at the provider; suspension does too. A global cap on live keys
(`VOICE_MAX_ACTIVE_KEYS`, default 2000) bounds total liability. Without a
management key configured the feature is simply off (501 / "not enabled").

Minting needs a **fresh second factor in the browser** (it spends the
operator's money), so the flow is: mint on `/my/voice`, then on each machine:

```
GET /api/v1/my/voice
→ 200 { voice: { provider: "openrouter", endpoint: "https://openrouter.ai/api",
                 model: "openai/whisper-1", api_key: "sk-or-v1-…",
                 monthly_limit_usd, usage_monthly_usd, expires_at,
                 voxtype: { backend: "remote", remote_endpoint: "https://openrouter.ai/api",
                            remote_model: "openai/whisper-1", env: "VOXTYPE_WHISPER_API_KEY" } } }
   { voice: null, message: "No voice key yet — mint one at …" }   when none exists
   501 when the server has no management key

POST   /api/v1/my/voice   → 201 same shape   (rotate; also allowed from a machine that already holds a token)
DELETE /api/v1/my/voice   → 204              (revoke)
```

`omarchy my voice setup` writes into `~/.config/voxtype/config.toml`:

```toml
[whisper]
backend = "remote"
remote_endpoint = "https://openrouter.ai/api"
remote_model = "openai/whisper-1"
```

and puts the key in `VOXTYPE_WHISPER_API_KEY` for the voxtype user service
(a drop-in under `~/.config/systemd/user/voxtype.service.d/`, mode 0600),
then restarts it. voxtype posts `multipart/form-data` (`file` as WAV,
`model`, `language`, `response_format=json`) to
`<remote_endpoint>/v1/audio/transcriptions` with the key as a Bearer token,
which is exactly OpenRouter's OpenAI-compatible transcription endpoint.
`omarchy my voice off` restores `backend = "local"` and removes the drop-in.

Audio leaves the machine only while dictating; my.omarchy.org never sees it.

## Web pages

| Path (on my.omarchy.org) | |
|---|---|
| `/` | Signed out: what this is. Signed in: overview — devices, latest snapshot, recent snaps, voice status |
| `/devices` | Connected machines; disconnect (step-up gated) |
| `/dotfiles`, `/dotfiles/:id` | Snapshots; file listing; download; delete |
| `/snaps` | Your live snaps with copyable links; delete |
| `/voice` | Mint / rotate / revoke; spend this month |
| `/setup` | The four commands |
| `/device` | The approval page (shared with publishing; the copy changes with the purpose) |

The registry dashboard (`/dashboard`) keeps publish tokens only; devices are
not listed there. The header links "My Omarchy" ↔ "Publishing" on both hosts.

## Client work (Quattro side, not in this repo)

`omarchy my login|logout|whoami`, `omarchy my sync push [--encrypt] | pull
[--id N] [--dry-run]`, `omarchy my snap share <file> [--title] [--ttl]`,
`omarchy my voice setup|off|status`; an omasnap "Share" action that shells
out to `omarchy my snap share`; and a `first-run` note. Everything above is
the contract they build against.

## Retention and housekeeping

- Dotfile snapshots: newest 10 per account; a push past that purges the oldest.
- Snaps: `Registry::CleanupJob` (hourly) purges expired ones, bytes included.
- Voice keys: `MyOmarchy::VoiceKeySweepJob` (daily) refreshes spend and
  finishes any provider-side delete that failed at revoke time.
- Deleting an account (admin) cascades through all three.
