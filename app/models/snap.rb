# A screenshot shared from omasnap. The share token is the whole access
# control for the public page: unguessable, never listed anywhere public,
# never in the sitemap, never indexed. Only its owner can see the list.
class Snap < ApplicationRecord
  MAX_IMAGE_BYTES = 12.megabytes
  MAX_PIXELS = 40_000_000
  # Storage retained per account across every live snap
  MAX_RETAINED_BYTES_PER_USER = 1.gigabyte
  MAX_TITLE_LENGTH = 120
  # Longest a client may ask a snap to live; nil = until deleted.
  TTL_OPTIONS = { "1h" => 1.hour, "1d" => 1.day, "7d" => 7.days, "30d" => 30.days, "never" => nil }.freeze
  # ~70 bits from the base58 alphabet — enumeration is hopeless, and the
  # alphabet has no lookalikes to mangle when read aloud.
  TOKEN_LENGTH = 12
  # Anchor-free for the router; the model validation anchors it.
  TOKEN_PATTERN = /[1-9A-HJ-NP-Za-km-z]{#{TOKEN_LENGTH}}/
  TOKEN_FORMAT = /\A#{TOKEN_PATTERN}\z/
  CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze

  belongs_to :user
  belongs_to :api_token, optional: true
  has_one_attached :image
  has_one_attached :preview

  validates :token, presence: true, uniqueness: true, format: { with: TOKEN_FORMAT }
  validates :title, length: { maximum: MAX_TITLE_LENGTH }, allow_nil: true
  validates :content_type, inclusion: { in: CONTENT_TYPES }
  validates :width, :height, numericality: { greater_than: 0 }
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_IMAGE_BYTES }
  validates :device_name, format: { with: ApiToken::DEVICE_NAME_FORMAT }, allow_nil: true

  before_validation { self.token ||= self.class.generate_token }

  scope :live, -> { where(hidden_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :expired, -> { where(expires_at: ...Time.current) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.generate_token = SecureRandom.base58(TOKEN_LENGTH)

  # Overridable (tests lower it); the constant is the documented default
  class_attribute :max_retained_bytes_per_user, default: MAX_RETAINED_BYTES_PER_USER

  # Public lookup: only a live snap answers. Hidden (taken down) and expired
  # ones are 404, indistinguishable from never-existed.
  def self.find_live_by_token(token)
    return nil unless token.to_s.match?(TOKEN_FORMAT)
    live.find_by(token: token)
  end

  def live? = hidden_at.nil? && (expires_at.nil? || expires_at.future?)
  def expired? = expires_at.present? && expires_at.past?
  def hidden? = hidden_at.present?

  def extension
    { "image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp" }.fetch(content_type)
  end

  def filename = "#{title.presence&.parameterize.presence || 'snap'}-#{token}.#{extension}"

  # Fuzzy counter — a view must never touch updated_at (and so the ETag)
  def record_view!
    self.class.where(id: id).update_all("views_count = views_count + 1")
  end

  # Admin takedown: the page and the bytes go dark immediately; the row stays
  # so the owner's list explains what happened.
  def hide!(actor:, reason: nil)
    update!(hidden_at: Time.current)
    AuditEvent.record!(actor:, action: "snap.hide", subject: self,
      metadata: { reason: reason.presence || "unspecified" })
  end
end
