# Package compatibility

Plugins and themes use the same policy. Author requirements describe supported versions and APIs; observed evidence describes one exact package archive on one exact Omarchy version/build. Ratings remain separate. A successful security scan does not prove compatibility, and neither scanning nor compatibility checks guarantee that a package is safe in every environment.

## Author contract

```json
{
  "schemaVersion": 1,
  "packageType": "theme",
  "compatibility": {
    "apiVersion": 1,
    "minOmarchyVersion": "4.2.0",
    "maxOmarchyVersionExclusive": "5.0.0"
  }
}
```

`schemaVersion` versions manifest syntax. `compatibility.apiVersion` versions the theme or plugin runtime contract independently. It is an integer between 1 and 10000, not an Omarchy release number. Omarchy ships its supported API arrays in `default/omarchy/package-apis.json`; add a new API when changing the package contract and retain older APIs only when the implementation genuinely supports them.

Minimum is inclusive, maximum exclusive. Both are optional strict semver strings, bounded to 64 characters with numeric components of at most ten digits. Build metadata is ignored for precedence. Unknown fields, conflicting minimum declarations, inverted ranges and noninteger API versions are rejected by both registry and client. This is deliberately not a general range-expression language.

Existing immutable releases without `compatibility` remain valid: top-level `minOmarchyVersion` still applies, and their original contract is API 1. They do not become “tested” through migration. New scaffolds declare API 1; creators should add honest version bounds. Changing a declaration requires publishing a new package version, never editing a released archive.

## Exact identities and evidence

Moderators register immutable release contracts at `/admin/omarchy_releases`, including version, build, channel and supported APIs. Candidate/development releases require a build. The client normalizes legacy `4.0.0.alpha` spelling to `4.0.0-alpha`.

Git checkouts use their full commit SHA; dirty checkouts append `.dirty` and must not be certified as the clean commit. Packaged installations use a shipped `build` file, or `pkg-<pacman-version>` including pkgrel (epoch colons become underscores). Register that exact value, not only the upstream version. A blank build is a distinct identity, not a wildcard. Changed bytes or API support require another build. Do not register local dirty variants as official candidates.

Reports are keyed by package version/SHA plus a cataloged Omarchy version/build. Only authenticated, email-verified accounts can report. One account has one editable report per pair, backed by a unique database constraint. Users choose works/problem, appearance/activation/other, and explicitly identify modified copies. Reports from modified copies, suspended accounts or unverified accounts do not affect public counts. These are attestations, not cryptographic proof of installation; account farming can affect warnings, never directly impose a block.

| Status | Meaning | Install policy |
| --- | --- | --- |
| Unknown | No working evidence; fewer than three problem reports | Allow within declared requirements; disclose untested |
| Reported working | At least one eligible working report | Allow; no claim of automated/runtime certification |
| Suspected | Three distinct eligible problem reporters, or a failed scoped check | Warn; never vote-block |
| Incompatible | Creator acknowledgment or moderator confirmation with public evidence | Exclude only the affected package archive and exact Omarchy build |

Positive reports and passing checks cannot override a confirmed decision. Publisher **owners** may acknowledge incompatibility; only moderators can clear a confirmed block. Both actions require fresh MFA, no sensitive-change cooldown, a reason/reproduction summary and a public audit event. A failure can be an Omarchy regression rather than a package bug. Clearing the decision does not erase unresolved reports or failed checks.

The public version page and JSON expose evidence and links. Reproduction details are escaped text, bounded to 4000 characters, visible only to the publishing team and moderators. The CLI opens a prefilled report page from the receipt or clone provenance; it sends no logs or diagnostics automatically. Report pages and private inboxes are not cacheable.

## Creator alerts

The compatibility inbox is linked from creator/admin dashboards. The first eligible problem, escalation to suspected, and confirmation each create at most one notification per accepted publisher member for that package/build. Repeated votes and retries do not generate a mail per report. Modified-copy-only reports remain available for investigation but do not trigger these aggregate alerts.

A durable outbox and recurring ten-minute job recover lost enqueues and retry temporary mail failures. Membership and suspension are checked again before delivery. SMTP acceptance and a database commit are not atomic: a worker crash after SMTP accepts a message can cause one duplicate on retry. Notifications link to current evidence rather than copying private logs into mail.

## Signed enforcement

`compatibility.json` and its detached `.sig` contain the immutable release catalog and mutable assessments, keyed by package id/version/SHA and Omarchy version/build. Signed `config.json` advertises `compatibilitySchemaVersion: 1`. The feed has a monotonic generation and a 24-hour expiry; the existing ten-minute data-plane job rebuilds it. Its signature, expiry, schema and rollback rules apply on installs, updates and pinned downloads. New clients fail closed when the registry does not support this feed.

Advisories do not rewrite archives, yank a release globally, or create a security revocation. Surviving signed decision revisions and release contracts are checked before regeneration; an older/missing database decision freezes the advisory until the audited database state is restored. A damaged advisory does not stop fresh security revocations or healthy package indexes. Back up the database and signed data together and keep the existing external restore witness configured; there is no automatic “clear all compatibility” recovery switch.

The client filters author bounds and unsupported APIs first, then exact-build confirmed advisories, while preserving existing yank/revocation rules. An unpinned resolver can choose another compatible release. It never silently downgrades an installed package. Unknown/suspected evidence is shown as a warning, including for `--yes` installs.

Before a development upgrade, the client requires a clean checkout, fetches, reads the target commit's version/API files without executing it, checks installed packages, and merges that same SHA. Before a packaged upgrade, it downloads with pacman, reads the actual candidate archive's version/build/API files, checks installed packages, then uses an exact pacman dependency constraint without another database refresh. Failed verification or confirmed incompatibility stops before installation. Conflict retries repeat the check. Direct package-manager overrides and other explicitly manual installation paths are outside this wrapper's guarantee.

Installed incompatible packages are preserved. The read-only checker suggests a compatible package update or a built-in theme fallback; it never treats ordinary breakage as malware or automatically deletes files. The separate six-hour user compatibility timer sends deduplicated warnings. Users can disable those notifications with the XDG-state `omarchy/package-compatibility-check-disabled` marker; install/upgrade checks remain enforced. Security revocation monitoring retains its own independent opt-out and quarantine policy.

## Release-candidate workflow

1. Build a trusted candidate, commit it, and register its exact version/build/API contract. For package testing use the actual built package identity, not a moving branch name.
2. Export immutable archives and their **verified signed index records**, including publisher, name, id, vers, sha256 and packageType. Keep the SHA with all results.
3. Run the companion `omarchy-package-compatibility-sweep --omarchy <clean-checkout> --archive <archive> --record <record.json> --image <image@sha256:digest>` for each archive. Supply a prebuilt image with Python 3.11+, Bash, GNU coreutils/awk/sed, jq and Lua's `luac`; the runner never pulls an image automatically.
4. Rootless Podman runs without networking, capabilities, host credentials or writable host mounts, with memory/process/CPU/time limits and temporary HOME. It validates theme palettes, generates candidate configs, checks unresolved substitutions and parses JSON/TOML/Lua/INI syntax. Other formats still need application acceptance. Plugin checks validate archives/manifests/entry points but never execute package code.
5. Use the existing Omarchy ISO acceptance harness for actual activation in a **disposable VM**, never the registry server or the working desktop. Boot the candidate, install the exact reviewed package into the throwaway user, and opt in to `test/acceptance.d/package-compatibility-test.sh` with `OMARCHY_ACCEPTANCE_DISPOSABLE=1`, `OMARCHY_COMPATIBILITY_PACKAGE_ID` and `OMARCHY_COMPATIBILITY_PACKAGE_TYPE`. Isolate the VM from host credentials, shared writable folders and production networking. The test restores theme/plugin state, captures a screenshot and writes scoped JSON evidence. Review representative applications and screenshots separately; a responsive shell alone does not prove every plugin behavior.
6. Review the output and import it on the release-contract admin page. The importer accepts only cataloged exact targets and matching immutable package SHAs. Failed checks warn and alert; confirmation still requires a moderator/creator decision. Infrastructure failures are inconclusive and do not erase an existing reproducible failure. A manifest pass cannot erase a desktop-activation failure.

No automated package execution is added to Rails. Container images, VM provisioning, real release catalog entries, scheduled RC campaigns and production mail delivery are operational rollout tasks; do not mark a candidate compatible merely because the runner is unavailable.

## Rollout

Deploy the additive database migration, regenerate and publish `compatibility.json` with signatures, and run the recurring jobs before releasing the companion client. Older clients ignore the new advisory/range/API fields, so do not promise enforcement until the client rollout is complete. Register real release/build identities before soliciting reports. No sample release catalog is seeded as if it had been tested.
