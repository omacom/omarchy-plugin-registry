# The static data plane: append-only JSON index + immutable tarballs, written
# to a local directory that production syncs to object storage behind the CDN.
# The Rails app is never in the install hot path — clients read these files.
#
# Layout (all paths relative to DataPlane.root):
#   config.json                      — dl/index URL templates for clients
#   index/<publisher>/<plugin>.json  — one JSON line per version (crates.io style)
#   all.json                         — compact listing for the directory + CLI search
#   revocations.json                 — the kill list (empty almost always)
#   dl/<publisher>/<plugin>/<plugin>-<version>.tar.gz
module DataPlane
  module_function

  def root
    Rails.application.config.x.data_plane_root
  end

  def base_url
    Rails.application.config.x.registry_base_url
  end

  def host
    URI(base_url).host
  end

  # Every index file gets a detached Ed25519 signature at <path>.sig. The
  # complete new content is STAGED first under a deterministic name, then the
  # signature promotes, then the staged content renames into place. Readers
  # never see a torn file, and a mismatched transient pairing FAILS
  # verification — clients retry, never trust a mismatched pair. A crash
  # between the two promotions leaves the staged content that the live sig
  # covers, so heal_interrupted_write! can complete the promotion; genuine
  # tamper has no matching staged content and stays fail-closed.
  def write(relative_path, content)
    path = root.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    atomic_write("#{relative_path}.staged", content)
    atomic_write("#{relative_path}.sig", Signer.sign_base64(content))
    File.rename(root.join("#{relative_path}.staged"), path)
    path
  end

  # Recovery from a write interrupted between sig and content promotion: if
  # the live pair mismatches but the staged content verifies against the live
  # sig, finish the rename. Anything else is left for the fail-closed checks.
  def heal_interrupted_write!(relative_path)
    path = root.join(relative_path)
    signature = root.join("#{relative_path}.sig")
    staged = root.join("#{relative_path}.staged")
    return unless staged.exist? && signature.exist?
    return if path.exist? && Signer.verify_any?(path.read, signature.read)
    File.rename(staged, path) if Signer.verify_any?(staged.read, signature.read)
  end

  def atomic_write(relative_path, content)
    path = root.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    temp = root.join("#{relative_path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
    temp.open("wb") { |f| f.write(content) }
    File.rename(temp, path)
  end

  # Tarballs are immutable: same bytes may be re-frozen idempotently (release
  # retries), different bytes for an existing path can never land.
  def freeze_tarball(version, bytes)
    path = root.join(version.tarball_path)
    if path.exist?
      return path if Digest::SHA256.file(path).hexdigest == Digest::SHA256.hexdigest(bytes)
      raise ArgumentError, "refusing to overwrite frozen tarball with different bytes: #{version.tarball_path}"
    end
    FileUtils.mkdir_p(path.dirname)
    atomic_write(version.tarball_path, bytes)
    path
  end

  def read(relative_path)
    root.join(relative_path).read
  end
end
