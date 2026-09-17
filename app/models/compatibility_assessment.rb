class CompatibilityAssessment < ApplicationRecord
  belongs_to :plugin_version
  belongs_to :omarchy_release
  has_many :compatibility_reports, dependent: :restrict_with_error
  has_many :compatibility_notifications, dependent: :restrict_with_error
  attr_readonly :plugin_version_id, :omarchy_release_id

  validates :plugin_version_id, uniqueness: { scope: :omarchy_release_id }
  validates :decision, inclusion: { in: %w[none incompatible] }
  validates :check_result, inclusion: { in: %w[not_run passed failed inconclusive] }
  validates :reason, :check_evidence, length: { maximum: 4000 }
  validates :reason, :check_evidence, format: { without: /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ }
  validates :reason, presence: true, if: -> { decision == "incompatible" }
  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def counts = compatibility_reports.eligible.group(:outcome).count

  def status(evidence = counts)
    return "incompatible" if decision == "incompatible"
    return "suspected" if check_result == "failed" || evidence.fetch("problem", 0) >= 3
    return "reported_working" if evidence.fetch("works", 0).positive?
    "unknown"
  end

  def entry(evidence = counts)
    { "id" => plugin_version.plugin.manifest_id, "vers" => plugin_version.version,
      "sha256" => plugin_version.sha256, "omarchyVersion" => omarchy_release.version,
      "omarchyBuild" => omarchy_release.build, "status" => status(evidence),
      "reason" => reason, "works" => evidence.fetch("works", 0), "problems" => evidence.fetch("problem", 0),
      "check" => check_result, "revision" => revision }
  end

  # Creators may acknowledge a break; only moderators clear a confirmed block.
  def decide!(actor:, decision:, reason:)
    unless actor.suspended_at.nil? && (actor.admin? || (decision == "incompatible" && actor.owner_of?(plugin_version.plugin.publisher)))
      raise ActiveRecord::RecordNotFound
    end
    raise ArgumentError, "An evidence/reproduction summary is required" if reason.to_s.strip.blank?
    with_lock do
      update!(decision:, reason:, revision: revision + 1)
      AuditEvent.record!(actor:, action: "compatibility.decision", subject: self, public: true,
        metadata: entry.merge("actor_role" => actor.admin? ? "moderator" : "creator"))
    end
    DataPlane::RegenerateJob.perform_later
    CompatibilityAlertsJob.perform_later(id)
  end

  def record_report!(user:, attributes:)
    raise ActiveRecord::RecordNotFound unless user.verified_at && user.suspended_at.nil?
    with_lock do
      report = compatibility_reports.find_or_initialize_by(user:)
      new_report = report.new_record?
      report.update!(attributes)
      if new_report || attributes.key?(:public_comment) || attributes.key?("public_comment")
        comment = report.comment || report.build_comment(user:, plugin: plugin_version.plugin)
        summary = report.outcome == "works" ? "Works for me." : "Reports a #{report.category == 'activation' ? 'loading' : report.category} problem."
        comment.update!(body: report.public_comment.presence || summary, updated_at: Time.current)
      else
        report.comment&.touch
      end
      touch
    end
    DataPlane::RegenerateJob.perform_later
    CompatibilityAlertsJob.perform_later(id)
  end
end
