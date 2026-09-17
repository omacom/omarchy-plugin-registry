# Passwordless, mirroring Cortex/Herald: sign-in is an emailed one-time code
# (LoginCode); TOTP — and eventually passkeys — is the second factor required
# to publish. No password ever exists to phish.
class User < ApplicationRecord
  has_many :compatibility_reports, dependent: :destroy
  has_many :compatibility_notifications, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :login_codes, dependent: :destroy
  has_many :memberships, dependent: :destroy
  # `publishers` means accepted affiliations only — pending invitations show
  # up nowhere except the invitation list
  has_many :accepted_memberships, -> { accepted }, class_name: "Membership"
  has_many :publishers, through: :accepted_memberships
  has_many :api_tokens, dependent: :destroy
  has_many :passkeys, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :ratings, dependent: :destroy
  has_many :reports, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # TOTP seed is encrypted at rest; backup codes are stored only as digests
  encrypts :otp_secret

  validates :email_address, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }

  # Publishing is blocked for a cooldown window after sensitive account changes
  # (email, MFA reset) — the npm post-worm posture.
  PUBLISH_COOLDOWN = 12.hours

  MAX_LOGIN_CODES_PER_HOUR = 5

  # Only ONE code is ever redeemable: issuing a new one consumes the rest, so
  # distributed requests cannot widen the guessable set. Issuance is capped
  # per account (on top of the per-IP throttle) against email bombing —
  # returns nil when throttled and sends nothing.
  def send_login_code
    with_lock do
      return nil if login_codes.where(created_at: 1.hour.ago..).count >= MAX_LOGIN_CODES_PER_HOUR
      login_codes.active.update_all(consumed_at: Time.current)
      login_codes.create!.tap do |record|
        LoginCodeMailer.sign_in_code(email_address,
          LoginCode.encrypt_for_delivery(record.plaintext_code)).deliver_later
      end
    end
  end

  # Atomic one-shot redemption: the UPDATE both finds and consumes the code in
  # one statement, so concurrent requests can't both redeem the same code.
  def redeem_login_code(code)
    consumed = login_codes.active.redeemable.where(code: LoginCode.digest(code.to_s.strip))
      .update_all(consumed_at: Time.current)
    if consumed == 1
      # Proof of mailbox ownership — flips the account out of the
      # pending-purge window forever
      update!(verified_at: Time.current) if verified_at.nil?
      true
    else
      # A wrong guess burns an attempt on every active code; codes lock after
      # LoginCode::MAX_ATTEMPTS so 6 digits can't be brute-forced.
      login_codes.active.update_all("attempts = attempts + 1")
      nil
    end
  end

  # Name + a claimed personal namespace = onboarded
  def onboarded? = name.present? && personal_publisher.present?

  def personal_publisher
    publishers.merge(Publisher.personal).first
  end

  def otp_enabled? = otp_enabled_at.present?

  # Lost-factor recovery: after a 72-hour delay (announced by email, visible
  # on every sign-in, cancellable by any successful step-up), factor
  # management reopens without step-up. The window gives the real owner time
  # to notice and shut a hijack down.
  RECOVERY_DELAY = 72.hours

  def recovery_pending? = recovery_requested_at.present? && recovery_requested_at > RECOVERY_DELAY.ago

  def recovery_ready? = recovery_requested_at.present? && recovery_requested_at <= RECOVERY_DELAY.ago

  # Publishing requires an unphishable-or-close second factor: a passkey
  # (preferred) or TOTP.
  def second_factor? = otp_enabled? || passkeys.exists?

  def can_publish?
    second_factor? && suspended_at.nil? && !in_publish_cooldown?
  end

  def in_publish_cooldown?
    sensitive_change_at.present? && sensitive_change_at > PUBLISH_COOLDOWN.ago
  end

  def otp_provisioning_uri(secret)
    ROTP::TOTP.new(secret, issuer: "plugins.omarchy.org").provisioning_uri(email_address)
  end

  # Returns the plaintext backup codes exactly once, at enrollment; only their
  # digests are persisted.
  def enable_otp!(code, secret:)
    # Enrollment confirms against the SESSION-BOUND provisional secret — it is
    # persisted to the account only in the same moment its confirmation lands,
    # so a transient session snoop can never pre-record a seed the real user
    # later confirms.
    return false if secret.blank? ||
      ROTP::TOTP.new(secret).verify(code.to_s.remove(/\s/), drift_behind: 15).blank?
    codes = Array.new(8) { SecureRandom.alphanumeric(10).downcase }
    update!(otp_secret: secret, otp_enabled_at: Time.current,
      otp_backup_codes: codes.map { |c| Digest::SHA256.hexdigest(c) })
    codes
  end

  # Step-up/second-factor verification: only a CONFIRMED enrollment counts —
  # a provisional secret captured pre-confirmation must never satisfy this.
  def verify_otp(code)
    return false unless otp_enabled?
    totp_matches?(code) || consume_backup_code(code)
  end

  # Only ACCEPTED memberships confer anything — an invitation is not an affiliation
  def owner_of?(publisher)
    memberships.accepted.exists?(publisher: publisher, role: :owner)
  end

  def member_of?(publisher)
    memberships.accepted.exists?(publisher: publisher)
  end

  private

  def totp_matches?(code)
    otp_secret.present? &&
      ROTP::TOTP.new(otp_secret).verify(code.to_s.remove(/\s/), drift_behind: 15).present?
  end

  # Locked read-modify-write: two concurrent redemptions can't both spend the
  # same one-time code
  def consume_backup_code(code)
    digest = Digest::SHA256.hexdigest(code.to_s)
    with_lock do
      digests = reload.otp_backup_codes || []
      return false unless digests.include?(digest)
      update!(otp_backup_codes: digests - [ digest ])
    end
    true
  end
end
