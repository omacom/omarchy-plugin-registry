require "net/http"
require "json"

module MyOmarchy
  # The slice of OpenRouter's management API voice keys need: create a
  # spend-capped, expiring key; read its usage; delete it. Authenticated with
  # a MANAGEMENT key that can only mint and manage other keys — it cannot
  # call a model — read from a file outside the app env (the same posture as
  # the AI-review credentials) or from OPENROUTER_MANAGEMENT_KEY.
  #
  # Tests inject a fake through config.x.open_router_client; production
  # resolves one lazily from configuration. No client = voice disabled.
  class OpenRouter
    class Error < StandardError; end
    class Unavailable < Error; end

    ENDPOINT = URI("https://openrouter.ai/api/v1/keys")
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15
    MAX_RESPONSE = 256.kilobytes

    Key = Struct.new(:hash, :secret, :label, :limit, :limit_remaining, :usage, :usage_monthly,
      :disabled, :expires_at, keyword_init: true)

    def self.client
      configured = Rails.application.config.x.open_router_client
      return configured unless configured.nil?
      key = management_key
      key.present? ? new(management_key: key) : nil
    end

    def self.management_key
      return ENV["OPENROUTER_MANAGEMENT_KEY"] if ENV["OPENROUTER_MANAGEMENT_KEY"].present?
      file = ENV["OPENROUTER_MANAGEMENT_KEY_FILE"].presence
      return nil unless file && File.file?(file)
      File.read(file, 4096).strip.presence
    end

    def initialize(management_key:, endpoint: ENDPOINT)
      @management_key = management_key
      @endpoint = endpoint
    end

    # Returns the Key with its one-time secret. limit is USD; limit_reset
    # monthly means the cap re-arms at midnight UTC on the first.
    def create_key(name:, limit_usd:, expires_at:, limit_reset: "monthly")
      body = { name: name, limit: limit_usd.to_f, limit_reset: limit_reset,
               expires_at: expires_at.utc.iso8601, include_byok_in_limit: true }
      parsed = request(Net::HTTP::Post, @endpoint, body)
      secret = parsed["key"]
      raise Error, "provider returned no key" if secret.blank?
      key_from(parsed["data"], secret: secret)
    end

    def get_key(hash)
      key_from(request(Net::HTTP::Get, key_uri(hash))["data"])
    end

    def delete_key(hash)
      request(Net::HTTP::Delete, key_uri(hash))
      true
    end

    def disable_key(hash)
      key_from(request(Net::HTTP::Patch, key_uri(hash), { disabled: true })["data"])
    end

    private

    def key_uri(hash)
      raise Error, "invalid key hash" unless hash.to_s.match?(/\A[0-9a-f]{16,128}\z/)
      URI("#{@endpoint}/#{hash}")
    end

    def key_from(data, secret: nil)
      raise Error, "malformed provider response" unless data.is_a?(Hash) && data["hash"].present?
      Key.new(hash: data["hash"], secret: secret, label: data["label"], limit: data["limit"],
        limit_remaining: data["limit_remaining"], usage: data["usage"].to_f,
        usage_monthly: data["usage_monthly"].to_f, disabled: data["disabled"] == true,
        expires_at: data["expires_at"].presence && Time.zone.parse(data["expires_at"]))
    end

    def request(klass, uri, body = nil)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@management_key}"
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      response = http.request(req)
      raw = response.body.to_s
      raise Error, "provider response too large" if raw.bytesize > MAX_RESPONSE
      # Provider error bodies are never surfaced: they can echo request
      # fields, and the status is all a caller can act on anyway.
      case response
      when Net::HTTPSuccess then JSON.parse(raw)
      when Net::HTTPUnauthorized, Net::HTTPForbidden then raise Unavailable, "provider rejected the management key"
      when Net::HTTPNotFound then raise Error, "provider key not found"
      when Net::HTTPTooManyRequests then raise Unavailable, "provider rate limit"
      else raise Unavailable, "provider returned #{response.code}"
      end
    rescue JSON::ParserError
      raise Error, "malformed provider response"
    rescue Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError => e
      raise Unavailable, "provider unreachable: #{e.class}"
    end
  end
end
