# Short-lived. Two purposes, two prefixes, two surfaces:
#
# * publish (omp_): push-only. Account-wide by default (like RubyGems/npm):
#   the token can publish to any namespace its user is a member of, which the
#   publish path enforces via membership regardless of the token. A non-null
#   publisher and/or plugin_name NARROWS the scope — trusted publishing (OIDC)
#   mints per-plugin tokens for CI.
# * account (oma_): what a machine holds for My Omarchy — dotfile sync, snap
#   sharing, fetching the voice key. It can never publish, and a publish
#   token can never reach the My API: authenticate() takes the purpose.
#
# The plaintext exists only at mint time; we store a SHA-256 digest. No
# long-lived classic tokens, ever.
class ApiToken < ApplicationRecord
  DEFAULT_TTL = 7.days
  ACCOUNT_TTL = 90.days
  MAX_TTL = 90.days
  PREFIXES = { "publish" => "omp_", "account" => "oma_" }.freeze
  PREFIX = PREFIXES["publish"]
  DEVICE_NAME_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  enum :purpose, { publish: 0, account: 1 }, prefix: true

  belongs_to :user
  belongs_to :publisher, optional: true

  attr_reader :plaintext_token
  # Machine-minted tokens (OIDC exchange) don't consume the user-managed quota
  attr_accessor :quota_exempt

  MAX_USABLE_PER_USER = 25
  # One per device, realistically; a hard ceiling so a leaked approval page
  # can't fan one account out to hundreds of machines.
  MAX_ACCOUNT_TOKENS_PER_USER = 10

  validates :plugin_name, format: { with: NameRules::NAME_FORMAT },
    length: { maximum: NameRules::MAX_LENGTH }, allow_nil: true
  # A plugin-scoped token must also name its namespace — plugin without
  # publisher is a nonsense scope.
  validates :publisher, presence: true, if: -> { plugin_name.present? }
  # An account token has no publish scope at all
  validates :publisher, absence: true, if: :purpose_account?
  validates :plugin_name, absence: true, if: :purpose_account?
  validates :device_name, format: { with: DEVICE_NAME_FORMAT }, allow_nil: true
  validates :expires_at, presence: true
  validate :ttl_within_bounds, on: :create
  validate :usable_quota, on: :create
  validate :publisher_not_suspended, on: :create

  scope :usable, -> { where(revoked_at: nil).where(expires_at: Time.current..) }

  def self.mint!(user:, publisher: nil, plugin_name: nil, ttl: nil, quota_exempt: false,
                 purpose: :publish, device_name: nil)
    purpose = purpose.to_s
    raw = PREFIXES.fetch(purpose) + SecureRandom.base58(30)
    token = create!(
      user:, publisher:, plugin_name:, purpose:,
      device_name: sanitize_device_name(device_name),
      token_digest: digest(raw),
      token_hint: "#{raw.first(8)}…#{raw.last(4)}",
      expires_at: (ttl || (purpose == "account" ? ACCOUNT_TTL : DEFAULT_TTL)).from_now,
      quota_exempt: quota_exempt
    )
    token.instance_variable_set(:@plaintext_token, raw)
    token
  end

  # Purpose is part of authentication, not a later check: a caller asking for
  # a publish token never receives an account token and vice versa, so no
  # controller can forget to look.
  def self.authenticate(raw, purpose: :publish)
    return nil if raw.blank?
    usable.where(purpose: purpose).find_by(token_digest: digest(raw))&.tap { |t| t.touch(:last_used_at) }
  end

  def self.digest(raw) = Digest::SHA256.hexdigest(raw)

  # A hostname as the CLI reports it, or nothing — never free text.
  def self.sanitize_device_name(value)
    name = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip
    name.match?(DEVICE_NAME_FORMAT) ? name : nil
  end

  def revoke! = update!(revoked_at: Time.current)

  def usable? = revoked_at.nil? && expires_at.future?

  # Scope is a widening hierarchy: account-wide (no publisher) authorizes any
  # target, namespace-wide (publisher, no plugin) authorizes any plugin in it,
  # per-plugin authorizes exactly one. Membership is enforced separately at
  # publish time, so an account-wide token can still only reach the user's own
  # namespaces. Account-purpose tokens authorize no publish target at all.
  def authorizes?(publisher_arg, plugin_name_arg)
    return false if purpose_account?
    return true if publisher_id.nil?
    return false unless publisher_id == publisher_arg.id
    plugin_name.nil? || plugin_name == plugin_name_arg
  end

  # Human-readable scope for tokens list / API responses.
  def scope_label
    return "my.omarchy.org · #{device_name.presence || 'device'}" if purpose_account?
    return "account (any of your namespaces)" if publisher_id.nil?
    plugin_name.nil? ? "#{publisher.name}/*" : "#{publisher.name}/#{plugin_name}"
  end

  private

  def ttl_within_bounds
    errors.add(:expires_at, "exceeds maximum lifetime") if expires_at && expires_at > MAX_TTL.from_now
  end

  def usable_quota
    return if quota_exempt || user.nil?
    if purpose_account?
      if user.api_tokens.usable.purpose_account.count >= MAX_ACCOUNT_TOKENS_PER_USER
        errors.add(:base, "too many connected devices — disconnect one first")
      end
    # Machine-minted (OIDC/provenance) tokens neither consume nor count toward
    # the user-managed quota — a CI burst must not lock a human out
    elsif user.api_tokens.usable.purpose_publish.where(provenance: nil).count >= MAX_USABLE_PER_USER
      errors.add(:base, "too many active tokens — revoke some first")
    end
  end

  # No stockpiling seven-day tokens against a suspended namespace to spend
  # the moment it's reinstated
  def publisher_not_suspended
    errors.add(:base, "publisher is suspended") if publisher&.suspended?
  end
end
