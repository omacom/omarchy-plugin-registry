# One entry in a plugin's version list. Install-critical bytes (sha256, size)
# are repeated here for display only — a client still resolves and verifies
# through the signed index at /index/<publisher>/<name>.json before installing.
json.version version.version
json.state version.state
json.yanked version.yanked?
json.yank_reason version.yank_reason
json.license version.license
json.min_omarchy_version version.min_omarchy_version
json.kinds version.manifest["kinds"]
json.package_type version.plugin.package_type
json.size_bytes version.size_bytes
json.sha256 version.sha256
json.published_at version.published_at
json.created_at version.created_at
json.url absolute_url(package_version_path(version.plugin, version.version))
