---
title: Omarchy Plugin Registry — Design Brainstorm
description: A real package-management solution for Omarchy Quattro plugins — hosted, scanned, revocable — modeled on npm, RubyGems, and the registries that learned the hard way.
---

> Package scope and storage extension (2026-09-05): [Plugins and themes in Omarchy Hub](packages.md) supersedes this historical design's theme deferral and client install-location decisions. The rest remains architectural background.

```mosaic-hero
{
  "eyebrow": "Design brainstorm · Draft 3",
  "title": "Omarchy Plugin Registry",
  "subtitle": "From \"paste a GitHub URL\" to a hosted, scanned, revocable plugin ecosystem at plugins.omarchy.org — before the first malicious plugin ships, not after.",
  "tags": ["Quattro", { "label": "Supply chain", "tone": "warning" }, { "label": "Architecture decided", "tone": "success" }, "plugins.omarchy.org"],
  "meta": { "Status": "Decisions locked, ready to spec", "Date": "2026-08-16", "Modeled on": "npm · RubyGems · crates.io · Flathub" }
}
```

```mosaic-callout
{
  "tone": "accent",
  "icon": "compass",
  "title": "The decided shape, in one paragraph",
  "body": "A **Rails control plane** at plugins.omarchy.org (registry-native accounts with mandatory publisher MFA — the same auth model as Cortex/Herald, no forge dependency), serving a **crates.io-style static data plane** (append-only JSON index + immutable, checksummed tarballs on a CDN). Publishing uses **short-lived scoped tokens as the universal path**, with OIDC trusted publishing as an accelerator on forges that support it; review is **fully automated with human escalation on flags and capability deltas**; the client gains `omarchy plugin add <publisher/name>` plus the one control every serious registry has and every failed one lacks: a **kill-bit** that disables an already-installed malicious plugin. Telemetry is server-side download counts only."
}
```

> **Implementation errata (2026-08-17):** the build deviates from this document in
> two places, both per Ryan's direction. (1) Accounts are fully passwordless —
> emailed one-time codes (the Cortex/Herald flow) with passkeys (UV required)
> or TOTP as the mandatory publisher second factor; no email+password exists.
> (2) Community identity is registry-native, not GitHub OAuth. Where this
> document says password or GitHub OAuth, read those instead.

## 1. Where we are today

Quattro's plugin system is deliberately minimal. The complete contract, extracted from the repo:

| Property | Today |
|---|---|
| Unit of distribution | One public git repo = one plugin, `manifest.json` at root |
| Install transport | `git clone` (HTTPS/SSH), **default-branch HEAD, no ref pinning** |
| Identity | `manifest.id` (`^[A-Za-z0-9][A-Za-z0-9._-]*$`, not `omarchy.*`); owner-prefixing is convention only, uniqueness enforced only per-machine |
| Install location | `~/.config/omarchy/plugins/<manifest.id>/` |
| Required manifest fields | `id`, `name`, `version`, `kinds`, `entryPoints` (`schemaVersion: 1`) |
| Versioning | `version` is required but **never compared anywhere**; git history is the version |
| Update | `git fetch` → show diff → `--ff-only` merge → re-validate → rollback on failure |
| Validation gate | `bin/omarchy-plugin-validate` (bash), mirrored in `PluginRegistry.qml` — path containment, no symlinks, kind/entry-point table, reserved namespace |
| Trust model | One scary confirmation at `plugin add`, then **unsandboxed arbitrary QML + bash** in the long-lived `omarchy-shell` process, forever |
| Discovery | A manual page pointing at omarchyplugins.com ("put it in a public git repo — that's the whole distribution mechanism") |

Two properties of the current design are genuinely good and worth preserving:

- **The installer never runs plugin code.** No install hooks, no sudo, no post-clone scripts. Install is a file copy; consent to *run* is a separate `enable` step.
- **The validate gate exists on both sides.** `omarchy-plugin-validate` runs at install, at update (with hard rollback), and again at load in QML — so a registry can reuse it server-side verbatim.

```mosaic-callout
{
  "tone": "info",
  "icon": "history",
  "title": "We already built a registry once — and deleted it",
  "body": "Commit `1bb43947` (May 2026) shipped a full CLI-side source registry: `omarchy plugin source add/list/remove`, `sources.json`, clone caches, `--ref` pinning, `omarchy plugin available`. Commit `798d6af8` (July 2026, DHH) removed all of it — 2,040 lines down to 1,080 — with an explicit design position: **\"Discovery belongs on a web page, not in the CLI.\"** That position is compatible with this proposal, and should shape it: all registry machinery lives server-side; the client stays a thin fetch-verify-unpack, and `git` remains the escape hatch for developers."
}
```

## 2. The threat: why GitHub-URL installs are a countdown

An Omarchy plugin is arbitrary QML loaded into a long-lived process with full user authority plus unrestricted shell via `bar.run()` / Quickshell `Process`. Installing from a pasted GitHub URL at unpinned HEAD means we have **exactly the AUR trust model** — and 2025 showed how every variant of that model fails:

```mosaic-signal-cards
{
  "signals": [
    {
      "signal": "The closest analogue",
      "title": "AUR: \"users will inspect the code\" empirically fails",
      "body": "July 2025: `firefox-patch-bin` and friends shipped the CHAOS RAT on the AUR, visible in plain sight in the PKGBUILD's source URL.",
      "evidence": "~46 hours live, caught only by community reports — on the single most security-literate Linux user base there is.",
      "implication": "Omarchy's audience is broader and less paranoid than Arch's. Trust-on-inspection will fail faster here, and helpers reduce inspection to a reflexive keypress.",
      "tone": "danger"
    },
    {
      "signal": "The real attack channel",
      "title": "Updates, not first submissions",
      "body": "Every major 2024–2025 registry incident came through the update channel of an already-trusted package: Cyberhaven's Chrome extensions (~2.6M users), the npm chalk/debug wave (~2.6B weekly downloads), Shai-Hulud 1 & 2 (500 → 796 packages, self-replicating), GlassWorm on Open VSX.",
      "evidence": "Obsidian reviewed first submissions by hand but never re-reviewed updates — that hole forced their May 2026 move to scanning every version.",
      "implication": "A review gate that only inspects new plugins secures the wrong door. Every version must pass the pipeline, and the publish credential is part of the attack surface.",
      "tone": "warning"
    },
    {
      "signal": "Current mechanics make it worse",
      "title": "Unpinned HEAD means silent retargeting",
      "body": "Installs and updates track the default branch. A compromised or sold author account rewrites what thousands of machines will pull tomorrow, with no version to yank because versions don't exist.",
      "evidence": "`omarchy-plugin-update` shows a diff and asks — but a `--ff-only` merge of minified or Unicode-obfuscated QML is not a meaningful consent moment.",
      "implication": "We need immutable, checksummed, revocable versions — and a way to reach machines that already installed a bad one.",
      "tone": "danger"
    }
  ]
}
```

One mitigating fact: Omarchy plugins have **no dependency graph** — no plugin depends on another plugin. That removes the entire transitive-trust problem that makes npm's situation so hard, and it's worth keeping that way as long as possible.

## 3. How the big registries actually work

Condensed from deep research (sources at the end); the details that matter for our design:

### npm — scale, and what it cost them

- Publish = authenticated PUT of a tarball; **granular tokens** scoped per-package with forced expiry (post-Shai-Hulud: 7-day default, 90-day max, classic tokens killed entirely).
- **Trusted publishing** (OIDC from GitHub Actions, GA July 2025) plus Sigstore **provenance attestations** linking a tarball to repo + commit + workflow.
- Immutability: a used `name@version` is burned forever; unpublish only within 72h; malware gets replaced by a `security-holding` placeholder so the name can't be resurrected.
- Since July 2026: **publish-time malware scanning holds every package ~5–15 minutes** before it becomes installable — worm-speed propagation died to a cheap delay.
- Scopes (`@user/pkg`) bound to accounts are the standard typosquat/dependency-confusion defense.

### RubyGems — the closest cultural fit

- Rails app + append-only **compact index** (`/versions`, `/info/<gem>` with SHA-256 per version) fetched incrementally via ETag + Range; tarballs on S3/CDN. This is the "Rails control plane, static data plane" pattern working at 100M+ downloads/day.
- Scoped API keys (push-only, per-gem), MFA mandatory above download thresholds, trusted publishing since Dec 2023, Sigstore attestations shipping.
- Cautionary tale: the 2025 Ruby Central governance fracture (maintainers removed, gem.coop fork). **Registry governance and key custody are part of the threat model** — write down who can take things down before it matters.

### crates.io — the serving model to copy

- The index is **static files at computable paths** (one JSON-lines file per crate + a root `config.json`), served over plain HTTP with per-file 304 revalidation; immutable tarballs on a dumb CDN at `/{name}/{name}-{version}.crate`. ~19B requests/month with almost no server in the hot path.
- Versions are permanent; **yank flips a boolean** — yanked versions stay downloadable for reproducibility but leave new resolution. No registry-side install hooks, ever.
- At Omarchy's scale this degenerates beautifully: the whole index can be regenerated as static files on every publish.

### The curated registries — what scales and what doesn't

```mosaic-table
{
  "columns": ["Registry", "Model", "Verdict for us"],
  "rows": [
    ["Flathub", "PR submission, humans review permission deltas only; builds happen on Flathub's infra", { "label": "Steal the delta idea", "tone": "success" }],
    ["VS Code Marketplace", "Automated AV + sandbox detonation on every version; signed; client-fetched kill list force-uninstalls malware", { "label": "Steal the kill-bit", "tone": "success" }],
    ["Chrome Web Store", "Automated + human review; MV3 bans remotely-loaded code so the reviewed artifact is the whole program", { "label": "Reviewed bytes = executed bytes", "tone": "success" }],
    ["Obsidian (pre-2026)", "PR adds entry to a catalog JSON; downloads from the author's own GitHub releases; updates never re-reviewed", { "label": "The hole we must not copy", "tone": "danger" }],
    ["Home Assistant HACS", "Catalog PR, structural checks only, code from author repos, unsandboxed", { "label": "Omarchy today, with extra steps", "tone": "danger" }],
    ["Arch AUR", "Zero pre-publication review; trust-on-inspection", { "label": "The countdown we're escaping", "tone": "danger" }]
  ]
}
```

The pattern in the failures is identical: **catalog-only registries that let clients download from author-controlled locations cannot take anything down and cannot see updates.** Hosting the bytes ourselves is the whole ballgame — which is exactly the instinct behind this project.

### Automated review, as actually deployed

- **Deterministic**: GuardDog-style Semgrep rules (curl-pipe-sh, base64→eval, obfuscation entropy, invisible-Unicode — the GlassWorm trick), install-hook detection, metadata anomalies (dormant plugin suddenly updated, publisher change).
- **Capability diffing** (Flathub): compute what a version *can do*; only versions whose capability surface **grows** get held for a human. This is the only human-review model that scales.
- **LLM review is real**: Socket.dev runs LLM review on every new package within seconds, human-validated before action (peer-reviewed at ICSE 2025). Known counter-attack: prompt-injecting the scanner — the AI verdict must gate escalation, never auto-approve alone.
- **Backstops**: PyPI-style quarantine (uninstallable but not deleted, pending investigation) cut malware lifetime from months to hours; publish-time hold windows kill worms.

## 4. Decisions made

All core architecture calls are now settled:

```mosaic-table
{
  "columns": ["Question", "Decision", "Notes"],
  "rows": [
    ["Backend", { "label": "Rails control plane + static data plane", "tone": "success" }, "Analysis in §5.1"],
    ["Review gate", { "label": "Fully automated, human gate on flags", "tone": "success" }, "§6 designs the pipeline around this"],
    ["Distribution", { "label": "Registry-hosted immutable tarballs", "tone": "success" }, "Analysis in §5.2; pacman stays for Omarchy's own package set"],
    ["Telemetry", { "label": "Server-side counts only", "tone": "success" }, "§8; the kill-bit fetch is security, not telemetry"],
    ["Domain", { "label": "plugins.omarchy.org", "tone": "success" }, "omarchyplugins.com gets absorbed and redirects"],
    ["Identity & auth", { "label": "Registry-native accounts, forge-agnostic", "tone": "success" }, "Cortex/Herald-style login, publisher MFA mandatory; GitHub, Codeberg, self-hosted forges all equal (§8)"],
    ["Namespaces", { "label": "First-claim, npm/RubyGems style", "tone": "success" }, "publisher/name; org rosters in-app; typosquat checks at claim; repo-proof only for grandfathering (§8)"],
    ["Git-URL installs", { "label": "Demoted to --unsafe at launch", "tone": "success" }, "Kept for dev/testing only, warning stays loud (§9)"],
    ["Community features", { "label": "Ratings, comments, views, downloads — all of it", "tone": "success" }, "§8; needs a moderation story, GitHub OAuth accounts already cover identity"],
    ["Governance", { "label": "Admin roster will be published", "tone": "success" }, "§7"],
    ["Multi-plugin repos", { "label": "Indifferent — default to one plugin per tarball", "tone": "info" }, "The tarball is the unit; nothing stops revisiting later"],
    ["Capability enforcement in the shell", { "label": "Parked — separate brainstorm", "tone": "warning" }, "Fingerprints ship as review + display metadata first (§6, §8)"]
  ]
}
```

## 5. The two architecture calls, argued (now decided)

### 5.1 Backend: Rails app vs. git-hybrid

```mosaic-table
{
  "title": "Rails control plane vs. git-PR hybrid",
  "columns": ["Dimension", "Rails app", "Hybrid (PR submission → app serves)"],
  "rows": [
    ["Fully-automated review", { "label": "Native", "tone": "success" }, { "label": "Awkward", "tone": "warning" }],
    ["Publish latency", "Seconds–minutes (API + scan hold)", "Minutes–hours (PR + CI + merge + ingest)"],
    ["Accounts / publisher identity", "GitHub OAuth, first-class", "GitHub identity implicit in PRs; still need accounts for ownership, yank, tokens"],
    ["Instant takedown / quarantine / kill-bit", { "label": "One admin action", "tone": "success" }, "Needs the app anyway — the git repo can't revoke"],
    ["Transparency / auditability", "Public audit log + mirrorable static index (earned back)", { "label": "Free via PR history", "tone": "success" }],
    ["Ops burden", "One Rails app + Postgres + object storage + CDN", "App + catalog repo + CI + ingest sync (two systems to keep coherent)"],
    ["Team fit", { "label": "This is a Rails shop; RubyGems.org is Rails", "tone": "success" }, "More moving parts, less familiar shape"]
  ]
}
```

The hybrid's advantages (transparent submissions, low-cost start) were designed for *human-reviewed* registries — Flathub and Obsidian use PRs because a human needs a place to comment. We chose fully-automated review, which turns the PR into pure ceremony: a bot opens it, a bot approves it, a bot merges it, and an app ingests it. Meanwhile every hard requirement — instant takedown, quarantine states, token minting, OIDC exchange, telemetry, the kill list — lives in the app in **both** options.

```mosaic-callout
{
  "tone": "success",
  "icon": "gem",
  "title": "Decision: Rails control plane, static data plane",
  "body": "Build **one Rails app** — but make it serve the RubyGems/crates.io way: the app handles accounts, publish, review, and admin; on every accepted publish it regenerates **static index files + immutable tarballs** pushed to object storage behind a CDN. Installs never touch the Rails app in the hot path, the registry survives app outages, and the index is mirrorable — which recovers the hybrid's transparency via a public, diffable index plus an audit-log page rather than PR theater."
}
```

### 5.2 Distribution: registry tarballs vs. Arch packages

```mosaic-table
{
  "title": "Registry-hosted tarballs vs. pacman packages",
  "columns": ["Dimension", "Registry tarballs", "Arch packages (omarchy repo)"],
  "rows": [
    ["Install location fit", { "label": "Perfect", "tone": "success", "body": "Plugins live per-user in ~/.config/omarchy/plugins; a tarball unpacks exactly there" }, { "label": "Mismatch", "tone": "danger", "body": "pacman installs system-wide to /usr as root; per-user enable state in shell.json doesn't map" }],
    ["Update cadence", "Independent per-plugin, instant", "Coupled to system upgrades; partial upgrades are unsupported on Arch"],
    ["Author friction", { "label": "Tag a release", "tone": "success" }, { "label": "Write + maintain a PKGBUILD", "tone": "danger" }],
    ["Takedown reach", "Kill-bit can disable installed copies (§7)", "Removing from the repo stops new installs only; pacman caches keep serving locally"],
    ["Multi-user machines", "Per-user installs, per-user consent", { "label": "One genuine win", "tone": "info", "body": "A system-wide install could serve all users — but consent-to-run is per-user anyway" }],
    ["Signing / delivery infra", "We build it (checksums + minisign/Sigstore — small, well-trodden)", { "label": "Free from pacman", "tone": "success", "body": "GPG signing, mirrors, resume, deltas" }],
    ["Non-Arch future", "Portable to any distro Omarchy might touch", "Arch-only forever"]
  ]
}
```

```mosaic-callout
{
  "tone": "success",
  "icon": "package",
  "title": "Decision: registry-hosted tarballs",
  "body": "Arch packaging is the wrong tool here: plugins are **per-user config-dir artifacts** with per-user enable state, and pacman is a **root, system-wide, whole-system-upgrade** mechanism. The delivery/signing infrastructure pacman would give us is the easy 10% of the problem — checksums in the index plus a detached signature on the index (minisign or Sigstore) replaces it in a weekend. Everything else about pacman (PKGBUILD friction, coupled upgrades, no revocation reach, Arch-only) fights the design. Keep pacman for what it's already for: Omarchy's own package set."
}
```

Distribution is **push-only**: the author uploads a tarball (`omarchy plugin publish` or CI), and on approval those exact bytes are frozen as the **immutable tarball** `<name>-<version>.tar.gz`, checksummed in the index. The registry never pulls from a repo — the author's forge (or absence of one) is irrelevant at publish and install time alike, there's no fetch gap between what was scanned and what is served, and takedown actually means something. Reviewed bytes are executed bytes (the Chrome MV3 lesson).

## 6. The review pipeline

Fully automated, human gate only when something pops — designed so the human queue stays near-empty:

```mosaic-sequence
{
  "title": "Every version, every time — no update skips the pipeline",
  "steps": [
    { "number": 1, "title": "Structural validation", "timing": "instant", "goal": "Reject malformed submissions before they cost anything", "body": "The submission is the tarball, nothing else — all registry metadata is **derived from the manifest inside it**, no sidecar metadata is accepted, which deletes npm's manifest-confusion bug class outright rather than validating against it. Then: server-side run of the existing `omarchy-plugin-validate` (it's already the security boundary — reuse it verbatim), version is valid semver **strictly greater** than the last published (a name@version is burned forever, even if yanked or rejected — no re-pushes, no same-version-different-bytes), no symlinks, entry-point containment, size limits, license present." },
    { "number": 2, "title": "Deterministic scanning", "timing": "seconds", "goal": "Catch the known-bad patterns mechanically", "body": "GuardDog-style Semgrep rules tuned for our stack — bash: curl-pipe-sh, base64→eval, writes outside plugin/config dirs, raw-IP network calls; QML/JS: `Process`/`execDetached` inventory, XHR targets, eval-like constructs, obfuscation entropy, invisible-Unicode detection (the GlassWorm trick). Plus metadata anomalies: publisher recently changed, long-dormant plugin suddenly active." },
    { "number": 3, "title": "Capability fingerprint + delta", "timing": "seconds", "goal": "Make human review scale by reviewing only changes in power", "body": "Static analysis emits a capability fingerprint: spawns processes (which binaries), network endpoints, filesystem reach, shell-IPC calls, keybinding hooks. First release records it; an update whose fingerprint **grows** is automatically held for a human (Flathub's model — the only human-review approach that scales). A clock widget that suddenly wants `curl` is exactly the case this catches." },
    { "number": 4, "title": "AI review", "timing": "≤ 15 min budget", "goal": "Advisory judgment alongside deterministic and human review", "body": "The tool-less reviewer receives complete bounded current source, with capability fingerprints, scan results and explicitly partial previous-source context on updates. Missing coverage, provider errors or invalid verdicts quarantine the version; source is never silently dropped to fit context. **A pass cannot override deterministic findings, first-executable-release review, or mandatory human judgment on dynamic call sites.** Submissions and model output are data, never executable instructions. Runtime isolation and its deployment prerequisites are documented in docs/deploy.md." },
    { "number": 5, "title": "Hold window, then live", "timing": "~10–15 min total", "goal": "Kill worm-speed propagation for the price of a coffee", "body": "Even a fully clean version waits out a short hold before becoming installable (npm adopted this in July 2026 after Shai-Hulud). Then: tarball frozen to CDN, index regenerated, download counts start. Flagged versions sit in quarantine — visible on the web page as 'under review', uninstallable — until a human passes or rejects." }
  ]
}
```

Human escalation is a small admin queue in the Rails app: flagged versions, capability-delta holds, and abuse reports. Actions available: approve, reject with reason, quarantine the plugin, revoke the publisher, add to the kill list.

## 7. Takedown: the part that makes this worth building

Hosting the bytes buys three levels of response no catalog-over-GitHub model can offer:

| Level | Mechanism | Effect |
|---|---|---|
| Quarantine | Version flagged in DB, dropped from index on regen | New installs stop within CDN TTL (~minutes); bytes preserved for investigation |
| Yank / takedown | crates.io semantics — flag flips, name+version burned forever; plugin page shows a security notice; `security-holding` placeholder prevents name resurrection | Nothing resolves to it again, ever |
| **Kill-bit** | Tiny signed `revocations.json` on the CDN listing revoked `plugin@version` (or whole plugins). Client checks it on `plugin add`, on `plugin update`, and periodically (systemd user timer or shell-start check). A hit **disables the plugin immediately** via the existing IPC, renames the directory to a quarantine name, and notifies the user via `omarchy-notification-send`. | Reaches machines that already installed the malware — hours instead of never |

```mosaic-callout
{
  "tone": "warning",
  "icon": "shield-alert",
  "title": "The kill-bit fetch is a security control, not telemetry",
  "body": "We chose server-side-only telemetry, and that holds: the revocation list is a **cacheable, unauthenticated, unparameterized GET** of a file that is empty almost always — it carries no user data and identifies nothing. It should be documented as the one background network touch the plugin system makes, with a config switch for the allergic. VS Code's equivalent (a client-fetched malware list that force-uninstalls) is the single control that most separates the registries that contain incidents from the ones that just watch them."
}
```

Governance goes in writing on day one (the RubyGems 2025 fracture is the cautionary tale). Decided: we maintain a **published admin roster** — who can take down a version, who can revoke a publisher, who holds the index-signing key, and what the appeal path is. One page on the site; names and key-custody mechanics still to be assigned.

## 8. The registry, concretely

**plugins.omarchy.org** (Rails, Postgres, object storage + CDN):

- **Accounts**: registry-native — the same conventional auth model as Cortex and Herald (email + password, WebAuthn/TOTP MFA), with **no forge dependency**. GitHub is sometimes down and not everyone uses it; authors on Codeberg, Bitbucket, GitLab, or a self-hosted Forgejo are equal citizens. Forge login buttons can exist later as a convenience, but they'd map onto a registry account, never *be* the identity.
- **Names**: `publisher/name`, **first-come-first-served** like npm and RubyGems. A publisher is a registry account or an org created in-app; users install `ryanrhughes/asdf`, and at publish time the manifest `id` must equal `<publisher>.<name>` (`ryanrhughes.asdf`), making today's dot-convention a rule. `omarchy.*` stays reserved for first-party; names are burned forever once used.

### Namespaces, orgs, and account security

With first-claim namespaces and registry-native identity, we take on the two problems the derived-identity model solved for free — squatting and credential theft — and handle them the way the big registries learned to:

- **Orgs**: an org is created in-app and gets its own namespace; the creator is its owner and manages a member roster with roles (owner / publisher), mirroring npm orgs. No forge org verification needed — it's just our data.
- **Typosquat defenses at claim time**: RubyGems-style similarity checking (dots/dashes stripped, confusable characters normalized) against existing publishers and plugin names; reserved words (`omarchy`, command prefixes); claim rate limits on new accounts. Optionally, a **verified badge** for publishers who prove control of a domain or their linked repo — a display signal, not a gate.
- **Account security is now the front line.** Every major registry credential incident (npm's 2025 worm wave, the Cyberhaven Chrome extensions) started with a phished publisher login. So: **MFA is mandatory to publish** (WebAuthn preferred — unphishable, unlike TOTP), only short-lived scoped tokens exist, and npm-style cooldowns apply after email/MFA/ownership changes. The §6 metadata-anomaly scan (dormant plugin suddenly publishing, publisher roster just changed) is the backstop for takeovers that get through anyway.

### Seeding from omarchyplugins.com

Seed every listed plugin as **unclaimed**, under a publisher name derived from its listed source repo's owner (`ryanrhughes/asdf`), snapshotted at current HEAD through the full review pipeline like any publish. Because namespaces are otherwise first-claim, seeded names need protection: **claiming a seeded namespace requires one-time proof of control of the listed source repo** — commit a challenge file or push a matching release tag, on whatever forge the repo lives. Repo-proof is used *only* for grandfathering; once claimed, ordinary account ownership takes over and the repo link becomes plain metadata. Squatters can't touch seeded names, and no forge account is ever required to hold one afterward.
- **Publish paths**:
  1. **Short-lived token publish (the universal path)** — `omarchy plugin publish` (or `curl`): device-flow login mints a per-plugin, push-only token with forced expiry (npm's post-worm posture: 7-day default). Works identically whether your code lives on GitHub, Codeberg, a self-hosted Forgejo, or nowhere public at all. No classic long-lived tokens, ever — they are what fed every 2025 credential-phishing worm.
  2. **Trusted publishing (recommended accelerator where the forge supports OIDC)** — today that's GitHub Actions and GitLab CI, others as they grow `id-token` support: register repo + workflow + pinned `release` environment once; tagging a release publishes with no stored secret. PyPI-style *pending publishers* let the first CI publish create the plugin; block `pull_request_target`/`workflow_run` triggers and pin the environment (PyPI's resurrection-attack mitigations). Strictly optional — the registry never requires a forge.
- **Index** (static, regenerated on publish): root `config.json` + one JSON file per plugin (all versions, checksums, yanked flags, capability fingerprints) at computable paths + a compact all-plugins listing for the web directory and CLI search. Detached-signed (minisign or Sigstore). Mirrorable by anyone — that's the transparency story.
- **Tarballs**: immutable at `/dl/<publisher>/<name>/<name>-<version>.tar.gz`, SHA-256 in the index.
- **Web directory**: the plugin pages replace omarchyplugins.com (which we absorb; the old domain redirects) — readme render, versions, capability fingerprint displayed as a permission list ("runs commands: `curl`, `jq` · network: api.weather.com"), security-notice banners. This satisfies "discovery belongs on a web page" exactly.
- **Community signals — all of them**: ratings, comments, view counts, download counts on every plugin page. Registry accounts cover commenter identity (no anonymous comments — that alone kills most of the moderation tarpit), the admin queue from §6 doubles as the comment-report queue, and comments from the plugin's own publisher get a badge. Ratings and downloads feed directory sorting, which also gives authors a reason to prefer the registry over a bare git URL.
- **Telemetry**: CDN log aggregation → per-version download/update counts; views counted app-side on plugin pages. Nothing client-side — the machine running Omarchy never phones home.

### Manifest additions (still `schemaVersion: 1` — all additive)

| Field | Status today | Registry behavior |
|---|---|---|
| `version` | Required, never compared | Becomes real: semver, monotonic per plugin, drives update resolution |
| `license` | Read by nothing | Required to publish (SPDX id) |
| `author` | Read by nothing | Superseded by verified publisher identity; kept for display |
| `repository` | Doesn't exist | New, optional: source URL on any forge, shown in the directory; earns a "verified repo" badge (and provenance links, if published via OIDC) when the author proves control |
| `minOmarchyVersion` | Doesn't exist | New, optional: lets the client skip incompatible updates instead of breaking shells |

## 9. Client changes (deliberately thin)

The July teardown's lesson stands: the CLI stays fetch-verify-unpack, and everything clever stays server-side.

```mosaic-sequence
{
  "title": "omarchy plugin add acme/weather",
  "steps": [
    { "number": 1, "title": "Resolve", "body": "GET the plugin's index file from the CDN; pick latest non-yanked version compatible with `minOmarchyVersion`. Check `revocations.json` while we're there." },
    { "number": 2, "title": "Fetch + verify", "body": "Download the tarball; verify SHA-256 against the index (and the index signature). No git, no author-controlled hosts." },
    { "number": 3, "title": "Validate + place", "body": "Existing flow unchanged: `omarchy-plugin-validate` on the staged unpack, id-collision check, move to `~/.config/omarchy/plugins/<id>/`, write an install receipt (`source: registry`, name, version, sha) beside the manifest, IPC rescan. Land disabled; enable stays a separate consent step." }
  ]
}
```

- **`omarchy plugin update`** reads receipts: registry-installed plugins update by version resolution (finally meaningful) with the changelog/diff link shown from the plugin page; git-installed plugins keep today's fetch-diff-ff flow untouched.
- **`omarchy plugin add <git-url>` gets demoted at registry launch**: it requires an explicit `--unsafe` flag, keeps today's scary warning (or louder), and exists for development and testing only. Registry installs get a calmer confirmation that names the publisher and shows the capability summary. The manual stops documenting git URLs as a distribution mechanism — the registry becomes *the* path.
- **Search stays off the CLI** (`omarchy plugin add` + the website is the loop); at most, `add` without arguments can open the directory.
- Local dev is untouched: drop a folder in, rescan — no receipt means "local", never updated, never revoked.

## 10. Making publishing genuinely easy

The submission story we should be able to put in the manual:

> Scaffold with `omarchy plugin new` (manifest, Widget.qml, readme, an optional CI publish workflow). Push it anywhere — GitHub, Codeberg, your own Forgejo, or nowhere public at all. Create an account at plugins.omarchy.org, claim `you/plugin-name`, and run `omarchy plugin publish` — device-flow login in the browser, a short-lived token does the rest. Minutes later it's live with your readme as its page. Prefer hands-off? Wire the scaffolded workflow to trusted publishing and tagging `v1.0.0` publishes for you.

That's npm-grade ease with none of npm's credential surface, and no forge in the critical path. The scaffold ships both routes pre-written, so the secure path is also the zero-thought path.

## 11. Rollout

```mosaic-horizon
{
  "title": "Phased build",
  "columns": [
    { "title": "Phase 1 — Registry MVP", "tone": "accent", "items": ["Rails app: registry-native accounts (MFA for publishers), user + org namespaces, publish endpoint + CLI token flow", "Static index + immutable tarballs on CDN, checksums", "Structural validation server-side (reuse omarchy-plugin-validate)", "Web directory with plugin pages; absorb omarchyplugins.com + redirect", "Seed existing plugins unclaimed; claim via source-repo proof", "Client: add/update by publisher/name, receipts, kill-bit check; git-URL demoted to --unsafe", "Yank + quarantine + revocations.json + admin-roster governance page", "Download-count telemetry"] },
    { "title": "Phase 2 — Automated review + community", "tone": "info", "items": ["Deterministic scanner (Semgrep ruleset for bash/QML)", "AI review with quarantine-on-flag + admin queue", "Trusted publishing (OIDC) on forges that support it + pending publishers", "Publish hold window", "Capability fingerprints computed and displayed", "Ratings, comments, views; report queue shares the admin queue"] },
    { "title": "Phase 3 — Hardening", "tone": "muted", "items": ["Capability-delta holds for updates", "Index signing verified client-side (minisign/Sigstore)", "Provenance links (repo + commit + workflow) on plugin pages", "Maybe: themes join the same registry", "Maybe: shell-enforced capabilities (separate brainstorm first)"] }
  ]
}
```

Phase 1 is deliberately shippable without any scanning: hosting + immutability + kill-bit already beats today's model by more than scanning ever will. Review quality then improves behind the same publish API without touching clients.

## 12. What's still open

The original open questions were all answered on 2026-08-16 (resolutions folded into §4 and the sections above). What genuinely remains:

1. **Shell-enforced capabilities** — parked deliberately. Fingerprints ship as review + display metadata; whether the shell should *enforce* declarations (deny undeclared `Process` spawns) is a much bigger Quickshell project deserving its own brainstorm.
2. **Admin roster + key custody specifics** — the roster and governance page are decided; the actual names, the index-signing key storage, and the appeal-path wording need an owner.
3. **Seeding mechanics** — snapshot timing (seed all of omarchyplugins.com at once vs. as claimed?), how we notify existing authors to run the repo-proof claim, and what happens to a seeded plugin that fails the review pipeline (list it unclaimed-and-uninstallable with a notice, most likely).
4. **Comment moderation policy details** — identity via GitHub OAuth and a shared report queue are decided; thresholds, rate limits, and what gets auto-hidden are Phase 2 design work.

## References

```mosaic-link-list
{
  "title": "Highest-value sources",
  "links": [
    { "label": "Cargo registry index format + web API — the serving model to copy", "href": "https://doc.rust-lang.org/cargo/reference/registry-index.html" },
    { "label": "PyPI trusted publishers security model — OIDC done carefully", "href": "https://docs.pypi.org/trusted-publishers/security-model/" },
    { "label": "RubyGems compact index API — Rails app, static data plane", "href": "https://guides.rubygems.org/rubygems-org-compact-index-api/" },
    { "label": "Flathub build validation — capability-delta human review", "href": "https://docs.flathub.org/blog/improved-build-validation" },
    { "label": "GitHub's post-Shai-Hulud npm security plan", "href": "https://github.blog/security/supply-chain-security/our-plan-for-a-more-secure-npm-supply-chain/" },
    { "label": "GuardDog — reusable Semgrep-based package scanner skeleton", "href": "https://github.com/DataDog/guarddog" },
    { "label": "Obsidian's move to scanning every plugin version (May 2026)", "href": "https://obsidian.md/blog/future-of-plugins/" },
    { "label": "AUR CHAOS RAT advisory — why trust-on-inspection fails", "href": "https://lists.archlinux.org/archives/list/aur-general@lists.archlinux.org/thread/7EZTJXLIAQLARQNTMEW2HBWZYE626IFJ/" },
    { "label": "npm publish-time malware scanning (July 2026)", "href": "https://github.blog/changelog/2026-07-28-npm-publish-time-malware-scanning-and-dual-use-metadata/" },
    { "label": "PyPI Project Quarantine — takedown in hours, not months", "href": "https://blog.pypi.org/posts/2024-12-30-quarantine/" }
  ]
}
```
