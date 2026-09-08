class Plugin < ApplicationRecord
  # security_holding: name burned after a malware takedown — page shows a notice,
  # nothing installable, name can never be resurrected.
  enum :state, { active: 0, quarantined: 1, security_holding: 2 }

  belongs_to :publisher
  has_many :versions, class_name: "PluginVersion", dependent: :restrict_with_error
  has_many :revocations, dependent: :restrict_with_error
  has_many :ratings, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :reports, as: :reportable, dependent: :destroy

  # Renditions of the root preview shipped inside the latest PUBLISHED
  # tarball — regenerated whenever the effective latest version changes
  # (release, yank, takedown), never touched by in-review submissions.
  has_one_attached :preview_card
  has_one_attached :preview_detail

  # Grandfather escape for the seed importer ONLY: hundreds of legacy
  # marketplace plugins are named omarchy-* from before the reservation rule
  # existed. Users know them by those names, so seeds keep them; new
  # registrations stay blocked.
  attr_accessor :allow_reserved

  validates :name, presence: true, uniqueness: { scope: :publisher_id },
    length: { maximum: NameRules::MAX_LENGTH },
    format: { with: NameRules::NAME_FORMAT, message: "must be lowercase letters, digits, - or _" }
  validate :name_not_reserved, on: :create
  validate :name_not_confusable_within_publisher, on: :create

  before_validation { self.normalized_name = NameRules.normalize(name) }

  # after_commit, not part of refresh_latest_version!: rendition generation
  # decodes images and must never run inside a release/takedown transaction.
  # The job re-derives everything from the row, so last-writer-wins is safe.
  after_commit :sync_preview_later, if: :saved_change_to_latest_version?
  # Fresh stats as soon as a release introduces or changes the source repo —
  # the daily sweep handles drift after that.
  after_commit -> { Registry::RepoStatsJob.perform_later(self) }, if: :saved_change_to_repository_url?

  scope :listed, -> { where(state: :active) }

  # What the public directory shows: installable plugins only. Anything still
  # in review (first submissions, quarantines, seed placeholders) stays
  # private to the publisher's members and admins until it actually clears —
  # an unreleased listing is noise to everyone else.
  scope :directory_visible, -> {
    where.not(state: :security_holding).where.not(latest_version: nil)
  }

  # The manifest id installed clients use: today's dot-convention made a rule.
  def manifest_id = "#{publisher.name}.#{name}"

  def full_name = "#{publisher.name}/#{name}"

  def latest_published_version
    versions.published.order(version_sort_key: :desc).first
  end

  # Any version ever created — published, yanked, or rejected — burns name@version.
  def version_burned?(version_string)
    versions.exists?(version: version_string)
  end

  # The monotonicity baseline. Rejected versions still burn their exact number
  # but don't force future versions above them — a bogus 99.0.0 submission must
  # not brick the plugin's numbering forever.
  def highest_version
    versions.where.not(state: :rejected).order(version_sort_key: :desc).first
  end

  def installable?
    return false unless active? && latest_version.present?
    return self[:latest_size_bytes].present? if has_attribute?(:latest_size_bytes)

    versions.published.where(version: latest_version).where.not(size_bytes: nil).exists?
  end

  # Was this plugin ever released to the public? Yanked and revoked versions
  # keep their pages (users may hold installed copies and need the notice);
  # never-released submissions have no public story at all.
  def ever_public?
    latest_version.present? ||
      versions.where(state: [ :published, :yanked ]).exists? ||
      revocations.exists?
  end

  # Page-level gate: security holds stay public on purpose (the takedown
  # notice IS the point); unreleased plugins are visible only to the
  # publisher's members and admins.
  def visible_to?(user)
    security_holding? || ever_public? ||
      (user.present? && (user.admin? || user.member_of?(publisher)))
  end

  # Keeps the public page honest: latest_version AND the metadata shown beside
  # it always come from the latest *published* version — when that changes
  # (release, yank, quarantine), summary/kinds/repo/readme follow it.
  def refresh_latest_version!
    # Nothing to compute for taken-down plugins (avoids re-inspecting a
    # tarball per yank during a whole-plugin security hold)
    return update!(latest_version: nil, summary: nil, readme: nil) unless active?

    latest = latest_published_version
    if latest
      # Best effort only: a missing or unreadable historical tarball must
      # never block the takedown transaction this runs inside
      readme_content = begin
        latest.tarball.attached? ? Registry::TarballInspector.inspect_bytes(latest.tarball.download).readme : nil
      rescue StandardError
        nil
      end
      update!(
        latest_version: latest.version,
        summary: latest.manifest["description"],
        kinds: latest.manifest["kinds"] || [],
        category: latest.manifest["category"],
        tags: latest.manifest["tags"] || [],
        repository_url: latest.manifest["repository"],
        readme: readme_content
      )
    else
      update!(latest_version: nil, summary: nil, readme: nil, category: nil, tags: [])
    end
  end

  def average_rating
    return nil if ratings_count.zero?
    (ratings_sum.to_f / ratings_count).round(1)
  end

  # Attachment + meta move together (RefreshPreviewJob) — but render only when
  # both actually landed, so a half-synced row degrades to the text card.
  def preview? = preview_meta.present? && preview_card.attached?
  def preview_animated? = preview_meta["animated"] == true
  def preview_card_meta = preview_meta["card"] || {}
  def preview_detail_meta = preview_meta["detail"] || {}

  def sync_preview_later
    Registry::RefreshPreviewJob.perform_later(self)
  end

  def repo_stars = repo_stats["stars"]
  def repo_pushed_at = repo_stats["pushed_at"].presence && Time.zone.parse(repo_stats["pushed_at"])
  def repo_release = repo_stats.slice("release_tag", "release_url").presence

  # Production batches view increments through the cache store (Solid Cache —
  # its own database, no contention on the primary) and CleanupJob flushes
  # hourly; elsewhere the write is direct so counts are immediately visible.
  # SEEDED plugins whose only history is rejection revert to a visible
  # placeholder (the directory promised the catalog entry exists and is
  # uninstallable). Shared by the review pipeline and admin rejection.
  def revert_to_placeholder_if_orphaned_seed!
    seeded = !publisher.claimed? || versions.joins(:user).exists?(users: { system: true })
    if seeded && active? && versions.where.not(state: :rejected).none?
      update!(state: :quarantined)
    end
  end

  def record_view!
    if Rails.env.production?
      Rails.cache.increment("plugin_views:#{id}", 1, initial: 0, expires_in: 3.hours)
    else
      self.class.where(id: id).update_all("views_count = views_count + 1")
    end
  end

  def flush_cached_views!
    pending = Rails.cache.read("plugin_views:#{id}", raw: true).to_i
    return if pending.zero?
    Rails.cache.decrement("plugin_views:#{id}", pending)
    self.class.where(id: id).update_all([ "views_count = views_count + ?", pending ])
  end

  private

  def name_not_reserved
    errors.add(:name, "is reserved") if NameRules.reserved?(name) && !allow_reserved
  end

  def name_not_confusable_within_publisher
    return if name.blank? || publisher.nil?
    clash = publisher.plugins.where(normalized_name: NameRules.normalize(name)).where.not(id: id)
    errors.add(:name, "is too similar to existing plugin #{clash.first.name}") if clash.exists?
  end
end
