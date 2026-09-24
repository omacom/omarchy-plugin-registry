# A per-user OpenRouter API key minted through their management API, so a
# machine can transcribe dictation in the cloud (voxtype's remote backend)
# without holding a shared secret. Spend-capped per month and time-boxed at
# the provider; the cap is the whole cost control, so it is never the user's
# to raise. One active key per account — rotating mints a new one and deletes
# the old at the provider.
class VoiceKey < ApplicationRecord
  belongs_to :user

  # The secret is what a second machine fetches over the API, so it must be
  # readable — encrypted at rest, never logged, never in a page.
  encrypts :secret

  validates :provider, presence: true
  validates :provider_hash, presence: true, uniqueness: true
  validates :monthly_limit_usd, numericality: { greater_than: 0 }
  validates :expires_at, presence: true
  validates :device_name, format: { with: ApiToken::DEVICE_NAME_FORMAT }, allow_nil: true

  scope :active, -> { where(revoked_at: nil).where(expires_at: Time.current..) }

  def active? = revoked_at.nil? && expires_at.future?

  def remaining_usd = [ monthly_limit_usd - usage_monthly_usd, 0 ].max

  def exhausted? = usage_monthly_usd >= monthly_limit_usd

  # Local revocation only — the provider-side delete lives in the service so
  # a failed provider call can retry without the row lying about its state.
  def revoke_locally!
    update!(revoked_at: Time.current, secret: nil)
  end
end
