# In-memory stand-in for MyOmarchy::OpenRouter: records every call so a test
# can assert what the provider was told, and hands back deterministic keys.
class FakeOpenRouter
  attr_reader :calls, :keys

  def initialize(fail_with: nil)
    @calls = []
    @keys = {}
    @minted = 0
    @fail_with = fail_with
  end

  def create_key(name:, limit_usd:, expires_at:, limit_reset: "monthly")
    @calls << [ :create, { name:, limit_usd:, expires_at:, limit_reset: } ]
    raise @fail_with if @fail_with
    # A counter, not the live size: a rotated key must never reuse a hash
    hash = Digest::SHA256.hexdigest("key-#{@minted += 1}")
    secret = "sk-or-v1-#{SecureRandom.hex(16)}"
    @keys[hash] = MyOmarchy::OpenRouter::Key.new(hash: hash, secret: secret, label: "sk-or-v1-#{secret[-6..]}",
      limit: limit_usd, limit_remaining: limit_usd, usage: 0.0, usage_monthly: 0.0, disabled: false, expires_at: expires_at)
  end

  def get_key(hash)
    @calls << [ :get, hash ]
    @keys.fetch(hash) { raise MyOpenRouterNotFound }
  end

  def delete_key(hash)
    @calls << [ :delete, hash ]
    @keys.delete(hash) or raise MyOmarchy::OpenRouter::Error, "provider key not found"
    true
  end

  def disable_key(hash)
    @calls << [ :disable, hash ]
    @keys.fetch(hash).tap { |k| k.disabled = true }
  end

  def spend!(hash, monthly:)
    @keys.fetch(hash).usage_monthly = monthly
    @keys.fetch(hash).usage = monthly
  end

  MyOpenRouterNotFound = Class.new(MyOmarchy::OpenRouter::Error) do
    def message = "provider key not found"
  end
end
