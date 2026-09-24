# CLI login without ever typing credentials into a terminal (RFC 8628 shape):
# `omarchy plugin publish` (or `omarchy my login`) requests a code pair, the
# user approves the 8-char user code in the browser (MFA'd session), and the
# CLI polls until it receives a freshly minted token. The token plaintext is
# held encrypted only until the CLI claims it, then wiped.
#
# The purpose is fixed when the CLI starts the flow and shown on the approval
# page: a terminal asking to connect a device to My Omarchy is approved as
# exactly that and receives an account token, never a publish token.
class DeviceAuthorization < ApplicationRecord
  belongs_to :api_token, optional: true
  EXPIRATION = 15.minutes
  USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ23456789".chars.freeze # no lookalikes
  POLL_INTERVAL = 5 # seconds, advisory for clients

  enum :status, { pending: 0, approved: 1, denied: 2, claimed: 3 }
  enum :purpose, { publish: 0, account: 1 }, prefix: true

  belongs_to :user, optional: true
  belongs_to :publisher, optional: true

  attr_reader :plaintext_device_code

  scope :active, -> { where(expires_at: Time.current..) }

  # requested_* are UNAUTHENTICATED display hints from the CLI so the approval
  # page can show what the terminal wants instead of asking the human to
  # re-type it. They never grant anything: approval still binds to a namespace
  # the signed-in user is a member of, chosen in the browser.
  def self.start!(requested_publisher: nil, requested_plugin: nil, purpose: :publish, device_name: nil)
    raw = "omd_" + SecureRandom.base58(30)
    authorization = create!(
      device_code_digest: digest(raw),
      user_code: generate_user_code,
      expires_at: EXPIRATION.from_now,
      purpose: purpose,
      device_name: ApiToken.sanitize_device_name(device_name),
      requested_publisher_name: sanitize_hint(requested_publisher),
      requested_plugin_name: sanitize_hint(requested_plugin)
    )
    authorization.instance_variable_set(:@plaintext_device_code, raw)
    authorization
  end

  def self.sanitize_hint(value)
    hint = value.to_s.downcase.strip
    hint.match?(NameRules::NAME_FORMAT) ? hint : nil
  end

  def requested_scope? = requested_publisher_name.present? && requested_plugin_name.present?

  def self.find_by_device_code(raw)
    active.find_by(device_code_digest: digest(raw.to_s))
  end

  def self.find_by_user_code(code)
    active.pending.find_by(user_code: normalize_user_code(code))
  end

  def self.digest(raw) = Digest::SHA256.hexdigest(raw)

  def self.normalize_user_code(code)
    cleaned = code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    "#{cleaned[0, 4]}-#{cleaned[4, 4]}"
  end

  # Account-wide by default: the token can publish to any namespace the user
  # belongs to (membership is enforced at publish time). Passing a publisher
  # and/or plugin_name narrows it — kept for a future "tighter scope" UI.
  def approve!(user:, publisher: nil, plugin_name: nil)
    # An account-purpose request never carries a publish scope, whatever the
    # approval form posted
    publisher = plugin_name = nil if purpose_account?
    token = ApiToken.mint!(user:, publisher:, plugin_name:, purpose:, device_name:)
    # The EXACT minted token is referenced — polling must report this token's
    # expiry, not whichever same-scope token happens to be newest
    update!(status: :approved, user:, publisher:, plugin_name:, api_token: token,
      token_ciphertext: self.class.encryptor.encrypt_and_sign(token.plaintext_token))
    token
  end

  def deny!(user:)
    update!(status: :denied, user:)
  end

  # One-shot: the atomic status flip decides the single winner among
  # concurrent polls; only the winner decrypts.
  def claim!
    ciphertext = token_ciphertext
    claimed_rows = self.class.where(id: id, status: :approved)
      .update_all(status: :claimed, token_ciphertext: nil)
    raise ActiveRecord::RecordInvalid, self unless claimed_rows == 1 && ciphertext.present?
    self.class.encryptor.decrypt_and_verify(ciphertext)
  end

  def expired? = expires_at.past?

  def self.encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key("device_authorization_tokens", 32)
    )
  end

  def self.generate_user_code
    code = Array.new(8) { USER_CODE_ALPHABET.sample }.join
    "#{code[0, 4]}-#{code[4, 4]}"
  end
end
