class PluginVersion < ApplicationRecord
  # Rows are never destroyed once created: a name@version is burned forever,
  # even when rejected or yanked — no re-pushes, no same-version-different-bytes.
  enum :state, {
    processing: 0,   # uploaded, running the pipeline
    published: 1,    # live on the data plane
    held: 2,         # waiting out the publish hold window (Phase 2)
    quarantined: 3,  # flagged — visible as "under review", uninstallable
    yanked: 4,       # crates.io semantics: leaves resolution, page shows notice
    rejected: 5      # failed the pipeline; version stays burned
  }

  belongs_to :plugin
  belongs_to :user, optional: true
  # The credential that carried the submission — release re-checks its liveness
  belongs_to :api_token, optional: true
  # Human-approval provenance: set only by an explicit admin approve
  belongs_to :approved_by, class_name: "User", optional: true # submitting principal; release re-checks it
  has_many :daily_downloads, dependent: :destroy
  has_many :compatibility_assessments, dependent: :restrict_with_error
  has_one_attached :tarball

  validates :version, presence: true, uniqueness: { scope: :plugin_id }
  validate :version_is_strict_semver

  before_validation { self.version_sort_key = Semver.parse(version).sort_key if Semver.valid?(version) }
  before_destroy { throw :abort } # burned forever

  scope :resolvable, -> { published }

  def semver = Semver.parse(version)

  # States an admin approval or hold expiry may publish from. `processing` is
  # deliberately excluded: nothing publishes before the review pipeline ran.
  def releasable? = held? || quarantined?

  # THE capability baseline, shared by the pipeline and the admin inspection
  # page: the highest-versioned sibling that cleared review (published, held,
  # yanked, or quarantined-after-publish). One definition — the human must see
  # the same comparison the machine made.
  def review_baseline
    # Only LOWER-versioned predecessors: comparing against a higher sibling
    # that happened to review first would hide capability growth
    plugin.versions.where.not(id: id)
      .where(version_sort_key: ...version_sort_key)
      .where("state IN (:cleared) OR (state = :quarantined AND published_at IS NOT NULL)",
        cleared: [ self.class.states[:published], self.class.states[:held], self.class.states[:yanked] ],
        quarantined: self.class.states[:quarantined])
      .order(version_sort_key: :desc).first
  end

  # Review runs in semantic-version order: while a LOWER version is still in
  # the pipeline, this one waits so its baseline is the true predecessor.
  def lower_version_in_review?
    plugin.versions.where.not(id: id).processing
      .where(version_sort_key: ...version_sort_key).exists?
  end

  def yank!(reason:, actor:)
    transaction do
      update!(state: :yanked, yanked_at: Time.current, yank_reason: reason)
      plugin.refresh_latest_version!
      AuditEvent.record!(actor:, action: "version.yank", subject: self, public: true,
        metadata: { plugin: plugin.full_name, version:, reason: })
    end
  end

  # The original legacy-marketplace listing time, honored as published_at at
  # release. Gated on the system seed identity: ordinary publishes must never
  # backdate themselves through crafted provenance.
  def seed_listed_at
    return nil unless user&.system?
    timestamp = provenance&.dig("legacy", "listed_at")
    Time.zone.parse(timestamp.to_s) rescue nil
  end

  # The id this plugin shipped under on the legacy marketplace — the client's
  # migration key for adopting receipt-less legacy installs.
  def legacy_id
    provenance&.dig("legacy", "id").presence
  end

  # True when the seeded snapshot's EXACT commit carried passing legacy
  # verification (automated baseline or maintainer attestation). Gated on the
  # system seed identity so ordinary publishes can't smuggle trust in via
  # provenance.
  def seed_verified?
    user&.system? && provenance&.dig("legacy", "verified") == true
  end

  def tarball_filename = "#{plugin.name}-#{version}.tar.gz"

  # Path on the static data plane, relative to its root.
  def tarball_path = "dl/#{plugin.publisher.name}/#{plugin.name}/#{tarball_filename}"

  private

  def version_is_strict_semver
    errors.add(:version, "must be strict semver (MAJOR.MINOR.PATCH)") unless Semver.valid?(version)
  end
end
