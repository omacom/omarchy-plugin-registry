# No anonymous comments — registry accounts only, which alone kills most of
# the moderation tarpit. Reports land in the shared admin queue.
class Comment < ApplicationRecord
  FORBIDDEN_DISPLAY_CONTROLS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/

  belongs_to :plugin, counter_cache: true
  belongs_to :user
  has_many :reports, as: :reportable, dependent: :destroy

  validates :body, presence: true, length: { minimum: 3, maximum: 2_000 }
  validates :body, format: { without: FORBIDDEN_DISPLAY_CONTROLS }, if: :will_save_change_to_body?

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
