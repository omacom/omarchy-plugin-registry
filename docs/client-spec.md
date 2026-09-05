# Client contract — `omarchy plugin` ⇄ plugins.omarchy.org

This contract also serves `omarchy theme`. [packages.md](packages.md) defines the
theme manifest, typed endpoints, data/config/state layout, per-file receipts,
editable clones and migration rules. That extension supersedes the legacy
plugin-only paths and receipt assumptions below.

The registry-side contract for the Quattro CLI work. The client stays a thin
fetch-verify-unpack; everything clever is server-side. Git installs remain the
dev escape hatch behind `--unsafe`.

## Trust root

Pin the registry public key (fetch once from `GET /signing-key.pub`, ship a
copy with Omarchy). Every JSON file below has a detached Ed25519 signature as a
real sibling object at `<path>.sig` (base64 over the exact file bytes) — works
identically from Rails or a dumb object store/CDN. Verify before trusting; the
kill list especially.

## Endpoints (all static, CDN-cached)

| Path | Contents |
|---|---|
| `GET /config.json` | URL templates: `dl`, `index`, `revocations`, `signing_key`, `api` |
| `GET /index/<publisher>/<name>.json` | First line: meta record with `generated_at`/`expires_at`; then one JSON line per version: `id`, `vers`, `sha256`, `size`, `yanked`, `license`, `minOmarchyVersion`, `kinds`, `caps` |
| `GET /all.json` | Compact directory listing (search/`plugin available`) |
| `GET /revocations.json` | `{schemaVersion, revocations: [{plugin, version?, reason, revoked_at}], generated_at, expires_at}` — `version` absent = whole plugin |
| `GET /dl/<publisher>/<name>/<name>-<version>.tar.gz` | Immutable tarball |

**Freshness (rollback protection)**: every signed file carries
`generated_at`/`expires_at`. Two rules, both mandatory:

1. Reject expired files. For `revocations.json` (regenerated every 10 minutes,
   24h expiry) fail CLOSED: an expired kill list means the mirror is stale or
   rolled back, so treat installs/updates as blocked until a fresh one verifies.
2. **Monotonicity**: signed files carry an integer `generation` that strictly
   increases with every regeneration. Persist the last accepted generation per
   file and reject anything lower-or-equal-but-different — a still-unexpired
   older signed copy is a rollback and must not replace a newer kill list.
   (`generated_at` is informational; order by `generation`.)

**Cache skew**: a file and its sidecar `.sig` are cached independently, so a
fetch that straddles a regeneration can pair bytes and signature from
different generations. Fetch the file first, read its (still-unverified)
`generation`, and fetch the signature as `<path>.sig?g=<generation>` — the
query busts the mismatched cache entry while staying cacheable per
generation (the server ignores it). Retry once on verification failure;
only then treat it as an attack.

## Browse surfaces (for an in-desktop plugin directory)

Everything above is the **install** path: static, signed, and the only thing a
client may resolve a version from. A native browser needs a second, different
thing — the human layer the website renders — so the Rails app answers its
public read surfaces as JSON on the same URLs, negotiated by format:
`/plugins.json`, `/plugins/<publisher>/<name>.json`,
`/plugins/<publisher>/<name>/<version>.json`, `/publishers/<name>.json`.

Full reference, including query parameters, paging, and payload shapes:
**[browse-api.md](browse-api.md)**.

Two rules matter here rather than there:

**These are not a trust surface.** They are unsigned, they are served by Rails
rather than the CDN origin, and a client must never resolve or install from
them. Show them; then resolve the version, verify the checksum, and check the
kill list through the signed data plane exactly as above.

**Render `notices`.** They carry the warning banners the website shows —
security holds, quarantines, revocations, withdrawn versions — from the same
code path as the page, so a takedown can never be visible on the site and
invisible in the desktop browser.

## `omarchy plugin add <publisher>/<name>`

1. Fetch + verify the plugin's index file; pick the highest non-`yanked`
   version whose `minOmarchyVersion` is satisfied.
2. Fetch + verify `revocations.json`; abort if the selection is revoked.
3. Download the tarball; check SHA-256 against the index entry.
4. Existing flow unchanged: `omarchy-plugin-validate` on the staged unpack
   (the shared validation contract lives as data in the registry repo at
   `test/conformance/corpus/*.json` — run the same corpus against
   `omarchy-plugin-validate` in Quattro CI so the two validators can never
   silently diverge),
   id-collision check, move to `${XDG_DATA_HOME:-~/.local/share}/omarchy/plugins/<id>/`, land
   **disabled** (enable stays a separate consent step).
5. Write an install receipt next to the manifest:
   `{"source": "registry", "publisher": ..., "name": ..., "version": ..., "sha256": ...}`.
   Receipts also record registry origin, package type, optional version pin and
   file hashes/modes. No receipt means no registry update or revocation; local
   clones carry a separate origin record and are never automatically updated.
6. Show the capability summary (`caps`) in the confirmation prompt.

## `omarchy plugin update`

Receipted registry installs resolve by version (semver, non-yanked, compatible);
git installs keep today's fetch-diff-ff flow. Every update re-checks
`revocations.json`.

## Kill-bit check

On `add`, on `update`, and periodically (systemd user timer or shell start):
fetch + verify `revocations.json` (it is a tiny, cacheable, unparameterized GET,
empty almost always — document it as the one background network touch, with a
config switch to disable). On a hit for an installed plugin@version:

1. Disable the plugin immediately via the existing IPC.
2. Move the package into the user state quarantine directory, outside discovery.
3. `omarchy-notification-send` with the reason and a link to the plugin page.

## Publishing (CLI side)

- `omarchy plugin publish`: device flow — `POST /api/v1/device/code` →
  `{device_code, user_code, verification_uri, interval}`; open/show
  `verification_uri`, poll `POST /api/v1/device/token {device_code}` until
  `{token}`; then `POST /api/v1/plugins/<publisher>/<name>/versions` with
  `Authorization: Bearer <token>` and the tar.gz as the raw body. 201 means
  accepted into the review pipeline (live after a short hold), 409 means the
  version number is burned, 422 carries a human-readable validation error.
- Key rotation: the trust root (`signing-key.pub`) is pinned on first use.
  A rotation is a coordinated re-pin event — after the registry announces
  one, verify the new key out-of-band and re-pin; until then the client
  correctly fails closed on new-key signatures.
- Retention: a submission that never publishes (quarantined, untouched by
  review for 90 days) expires to rejected and its bytes are deleted; its
  version number stays burned forever. Rejected uploads lose their bytes
  after 30 days. Published and yanked bytes are kept indefinitely.
- CI: exchange a GitHub Actions OIDC token (`aud: plugins.omarchy.org`) at
  `POST /api/v1/trusted/exchange {token, publisher, plugin}` for a 30-minute
  publish token — the declared `publisher`/`plugin` scope is REQUIRED and
  matching is confined to it (a squatted registration of the same public repo
  under another namespace cannot deny your exchange). The
  job must run from a tag ref (`refs/tags/*`) inside the registered pinned
  environment; the repo's numeric identity is pinned on first exchange.
- `omarchy plugin new` should scaffold `manifest.json` (with `license`,
  `repository`), a widget, a readme, and the trusted-publishing workflow.
- Optional manifest fields the registry validates and the client validator
  must mirror (conformance corpus: `taxonomy_*.json`): `category` (one of the
  registry's curated category slugs) and `tags` (≤3 from the curated tag
  list). Unknown values are publish-time errors, not warnings.
- `omarchy plugin add publisher/name@1.2.0` pins an exact version: resolve
  that version line from the signed index (yanked lines never resolve),
  verify sha256, install, and record the pin in the install receipt so
  `omarchy plugin update` skips it until the pin is removed. The site's
  per-version pages advertise this syntax.
- Optional root preview: exactly one of `preview.png|jpg|jpeg|webp|gif`
  (animated GIF allowed). The registry renders card/detail/share images from
  it; a corrupt or format-mismatched preview fails the publish. Client-side
  `omarchy-plugin-validate` should check the magic bytes match the extension.

## Demotions at launch

`omarchy plugin add <git-url>` requires `--unsafe` and keeps the scary warning.
The manual stops documenting git URLs as a distribution mechanism.
