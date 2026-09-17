# No anonymous comments — registry accounts only, which alone kills most of
# the moderation tarpit. Reports land in the shared admin queue.
class Comment < ApplicationRecord
  belongs_to :plugin, counter_cache: true
  belongs_to :user
  belongs_to :compatibility_report, optional: true
  has_many :reports, as: :reportable, dependent: :destroy

  validates :body, presence: true, length: { minimum: 3, maximum: 2_000 }

  scope :visible, -> { where(hidden_at: nil) }

  def hidden? = hidden_at.present?

  # Comments from the plugin's own publisher get a badge
  def from_publisher? = user.member_of?(plugin.publisher)

  def hide!(actor:)
    update!(hidden_at: Time.current)
    AuditEvent.record!(actor:, action: "comment.hide", subject: self,
      metadata: { plugin: plugin.full_name })
  end
end
