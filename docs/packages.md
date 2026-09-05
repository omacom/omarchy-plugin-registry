# Plugins and themes in Omarchy Hub

Omarchy Hub is the working name for this shared directory. It hosts versioned artifacts, accounts and discovery; it does not replace Git hosting. Existing hostnames, keys, token scopes and protocol paths remain stable. A future public rename needs a separate DNS and client configuration rollout.

## One registry, two package types

A publisher owns one `publisher/name` namespace across plugins and themes. Every record has an immutable `package_type` of `plugin` or `theme`, selected by the first accepted manifest. Existing records default to `plugin`. The Rails `Plugin`/`PluginVersion` names and tables remain internal compatibility details; accounts, quotas, review jobs, release holds, immutable versions, provenance, comments, ratings, yanks and revocations are shared.

Publish plugins to `POST /api/v1/plugins/<publisher>/<name>/versions` and themes to `POST /api/v1/themes/<publisher>/<name>/versions`. The endpoint's type must match the archive manifest. Query parameters cannot change it. A scoped token authorizes the existing publisher/name identity for either type; the shared namespace prevents a second package from reusing a credential's target.

Signed version entries add `packageType`; its absence means `plugin` for old records. `all.json` keeps plugins in `plugins` and adds a separate `themes` array, so older clients do not offer themes as plugins. Both share the existing `/index/<publisher>/<name>.json`, tarball URLs, signatures, generation counters and revocation list. Revocations retain the historical `plugin` field for the manifest id of either package type.

The website has a mixed directory and type filters, plus `/themes` and `/themes/<publisher>/<name>[/<version>]` pages. JSON browsing uses `/packages.json` for everything, `/plugins.json` for plugins and `/themes.json` for themes. Entries expose `package_type` and the correct `install_command`. Browse data is unsigned and must never resolve installs.

## Theme package format

```json
{
  "schemaVersion": 1,
  "packageType": "theme",
  "id": "acme.night",
  "name": "Night",
  "version": "1.0.0",
  "license": "MIT",
  "kinds": ["theme"],
  "entryPoints": {"theme": "colors.toml"}
}
```

`colors.toml` is required. It has simple literal assignments: lowercase keys, quoted hex colors or gradients, and `mode`/`theme_type` values of `light` or `dark`. Required `#RRGGBB` keys are `accent`, `background`, `foreground`, `red`, `green`, `yellow`, `blue`, `magenta` and `cyan`. Extra colors can use `#RRGGBB`, `#RRGGBBAA`, `rgb(RRGGBB)` or `rgba(RRGGBBAA)` stops with an optional angle, such as `rgba(112233ee) rgb(445566) 45deg`. Comments and blank lines are allowed. Duplicate keys, escaping, interpolation, arbitrary strings and multi-line values are rejected.

Optional files:

- `shell.toml` and `shell.<section>.toml`, containing literal appearance settings: colors/gradients, numbers, booleans or short plain strings such as font names.
- `icons.theme`, naming an already installed icon theme; `chromium.theme`, containing three decimal RGB values; empty `light.mode`.
- One root `preview.png|jpg|jpeg|webp|gif`; images named `preview-unlock`, `lock`, `unlock` or `screensaver` with those extensions; wallpaper images directly under `backgrounds/`. The boot unlock picker uses `preview-unlock.png` and `unlock.png`; applying them remains a separate privileged boot configuration step, not part of theme installation.
- Root README/license/notice/changelog documents and Markdown under `docs/`.

Themes do not ship executable files, Lua/QML/JavaScript, installers, terminal configurations, VS Code extension installation instructions, fonts, binaries or arbitrary application overrides. Omarchy generates application configs from its own templates. This contract is intentionally narrower than a hand-written local theme. `omarchy theme new acme/night --from <installed-theme>` copies the supported data into a new authoring folder and reports omitted overrides. Preserve upstream licenses and attribution.

Themes allow 50 MiB compressed and 150 MiB expanded, with at most 2,000 archive entries. Text configuration is limited to 64 KiB per file. Plugins retain 10/50 MiB compressed/expanded limits. Both reject traversal, symlinks, hardlinks, devices, duplicate paths, conflicting paths, privileged modes, Git metadata and client-owned receipt/origin files. The client validates the exact archive and binds its manifest identity, version and type to the signed index before placing it on disk.

## What scan coverage means

Every theme passes structural validation, the existing deterministic scanner, full-content executable-payload checks on assets, capability extraction, the configured AI/human escalation policy and the publish hold. The same revocation and takedown controls apply to every version. A theme cannot gain plugin capabilities by changing its type in an update. Palette validation also runs locally before activation, independently of the presence of `.git` or a receipt in the managed theme store.

Scans reduce risk; they do not prove the absence of vulnerabilities, sandbox plugins, or remove bugs in image decoders. Executable plugins still run in the user's shell process. Local clones and `--unsafe` Git installs are not covered as immutable reviewed releases. The UI and documentation should describe the specific checks rather than promise a package is universally safe.

## User-space layout

| Purpose | Default location | Ownership and updates |
| --- | --- | --- |
| Downloaded plugins | `~/.local/share/omarchy/plugins/<id>/` | Managed release or explicit unsafe Git install |
| Downloaded themes | `~/.local/share/omarchy/themes/<id>/` | Managed release |
| Editable plugins | `~/.config/omarchy/plugins/<local-id>/` | User-owned clone or development copy |
| Editable themes | `~/.config/omarchy/themes/<local-id>/` | User-owned clone or overrides |
| Keys, generations and publish tokens | `~/.local/state/omarchy/registry/<registry>/` | Shared across package types, separated by registry |
| Quarantined releases | `~/.local/state/omarchy/quarantine/` | Kept for inspection/recovery; never discovered as installed packages |

These package paths honor `XDG_DATA_HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME`. Existing Omarchy theme activation state keeps its established `~/.local/state/omarchy/current` path; this change is not a migration of all desktop state. Built-in plugins and themes remain part of the Omarchy system package under `$OMARCHY_PATH`. All community package and clone operations run as the user, without sudo.

Downloaded code and wallpapers are application data. Config holds the user's authored changes. Runtime state, credentials and rollback counters belong in state. This keeps dotfile repositories from accumulating downloaded release payloads and keeps the intent of each location clear.

## Install, edit, update and recover

```sh
omarchy theme new acme/night
omarchy theme publish ./omarchy-night-theme
omarchy theme search night
omarchy theme add acme/night
omarchy theme set acme.night
omarchy theme clone acme.night my-night --apply
omarchy plugin clone acme/weather --edit
```

Plugin installs land disabled; enabling is a separate step or explicit `--enable`. Theme installs leave the current theme alone unless `--apply` is supplied. Both accept `publisher/name@version` pins, stored in the receipt. Updates resolve strict semantic versions, the package type and `minOmarchyVersion` against signed data from the receipt's original registry. If a newer release disappears or is yanked, updates refuse to downgrade the installed version. Revocations are enforced separately.

A registry receipt records the origin, version, archive SHA-256, optional pin and file hashes/modes. Updates compare the installed tree before and after downloading. Changes, added/deleted files or symlinks stop replacement and direct the user to clone. Previous versions are retained in hidden `.previous-<id>.*` folders. A crash during replacement cannot let temporary-directory cleanup destroy the previous install. Removed packages are also backed up rather than deleting local work.

`plugin clone` copies a built-in or installed plugin into config with a distinct id. It preserves runtime references and `omarchy.clonedFrom`, letting the existing shell clone-switching behavior activate the copy while keeping the source installed. Third-party source `acme.weather` becomes `<username>.acme-weather-local`. A theme clone has its own name and is applied only on request. Copies omit Git metadata and registry receipts, record lineage in `.local-origin.json`, and are never overwritten by the updater. Legacy Git theme clones import only declarative data: stripping Git metadata must not promote previously filtered remote code into trusted local configuration. Local edits do not alter the original or inherit its scan claim. Revocation does not delete an independently modified clone.

Legacy plugin receipts in config migrate to data when an update verifies their tree against the original signed release. If the old receipt has no file hashes, the client downloads and checks that original archive first. A modified tree, missing original release, local/managed name collision or unverifiable registry stops migration. Receipt-less development folders and symlinks are left in place. Legacy Git themes remain supported in config behind `theme install <url> --unsafe`; installation never replaces an existing directory, and updating skips dirty trees and uses fast-forward-only pulls.

After a registry install, a systemd user timer checks both types' revocations every 15 minutes with jitter, starting after two minutes. It fetches once per receipt registry, verifies signatures/freshness/generation, disables and quarantines revoked plugins, and quarantines revoked themes. An active revoked theme switches to the shipped Tokyo Night fallback. Failure to communicate with the shell is reported; the user must restart a still-running shell if immediate unload failed. Updates check revocations even for pinned installs. Disabling the timer does not permit installing a revoked release.

Disable automatic checks with `touch ~/.local/state/omarchy/package-revocations-check-disabled` (under `XDG_STATE_HOME` when set); the older plugin-only opt-out is honored. Re-enable by removing that marker and running `omarchy-package-monitor-enable`. If systemd is unavailable during install, the client reports how to start the timer once the desktop session is available.

## Rollout and verification

Version declarations, exact-build community reports, creator alerts, signed compatibility advisories and candidate checks are defined in [compatibility.md](compatibility.md). Compatibility and security review are separate claims.

Deploy the additive registry migration first, then roll out the companion client before announcing theme installation. Existing plugin endpoints and signing identities remain unchanged. Do not silently relocate dirty directories, relabel Git installs as reviewed releases, or rename a registry origin without a coordinated pin/token migration.

The paired theme corpus is in `test/conformance/corpus/theme_*.json` here and `test/shell.d/fixtures/package-store/corpus/` in Omarchy. Registry request tests cover shared publishing/review/revocation and browse isolation. Omarchy's `package-store-test.sh` runs real signed HTTP registry fixtures, install/clone/update/migration/revocation behavior, palette activation and malicious archives, with temporary user homes and custom XDG roots.
