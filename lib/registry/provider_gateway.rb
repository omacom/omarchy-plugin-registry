require "json"
require "net/http"
require "uri"
require "timeout"

module Registry
  # A fixed-destination JSON relay, not a forward/CONNECT proxy. Only this
  # container owns provider credentials or has an external network route.
  class ProviderGateway
    MAX_REQUEST = 8 * 1024**2
    MAX_RESPONSE = 1024**2
    REQUEST_KEYS = %w[model messages stream temperature max_tokens max_completion_tokens reasoning_effort thinking system output_config].freeze

    def self.from_directory(path = "/ai", allow_http: false)
      values = %w[openrouter_key openai_key anthropic_key base_url model effort chunk_chars].to_h do |name|
        file = File.join(path, name)
        value = File.file?(file) ? File.read(file, 8193).strip : nil
        raise ArgumentError, "oversized provider configuration" if value && value.bytesize > 8192
        [ name, value.to_s.empty? ? nil : value ]
      end
      if values["openrouter_key"]
        # OpenRouter uses the OpenAI wire format. Its key is never sent to a
        # stale local-model base_url left over from another deployment.
        raise ArgumentError, "OpenRouter cannot be combined with another provider" if
          %w[openai_key anthropic_key base_url].any? { |name| values[name] }
        return new(provider: "openrouter", endpoint: "https://openrouter.ai/api/v1", key: values["openrouter_key"],
          model: values["model"] || "meta/muse-spark-1.3-contributor", effort: values["effort"] || "high",
          chunk_chars: Integer(values["chunk_chars"] || 120_000))
      end
      provider = values["openai_key"] || values["base_url"] ? "openai" : "anthropic"
      key = provider == "openai" ? values["openai_key"] || ("local" if values["base_url"]) : values["anthropic_key"]
      endpoint = values["base_url"] || (provider == "openai" ? "https://api.openai.com/v1" : "https://api.anthropic.com/v1")
      new(provider:, endpoint:, key:, allow_http:, model: values["model"] || (provider == "openai" ? "gpt-5.6-sol" : "claude-opus-5"),
        effort: values["effort"] || "high", chunk_chars: Integer(values["chunk_chars"] || 120_000))
    end

    def initialize(provider:, endpoint:, key:, model:, effort: "high", chunk_chars: 120_000, allow_http: false)
      raise ArgumentError, "invalid provider configuration" unless %w[openai anthropic openrouter].include?(provider) && key && !key.empty?
      @uri = URI.parse(endpoint)
      unless @uri.is_a?(URI::HTTP) && @uri.host && (@uri.scheme == "https" || allow_http) && !@uri.userinfo && !@uri.query && !@uri.fragment
        raise ArgumentError, "provider endpoint requires HTTPS (HTTP needs explicit operator opt-in)"
      end
      raise ArgumentError, "invalid review budget" unless chunk_chars.between?(1024, 120_000)
      @provider, @key, @model = provider, key, model
      @config = { provider: provider == "openrouter" ? "openai" : provider, model:, effort:, chunk_chars: }
      @leaf = provider == "anthropic" ? "messages" : "chat/completions"
    end

    def call(env)
      if env["REQUEST_METHOD"] == "GET" && env["PATH_INFO"] == "/configuration" && env["QUERY_STRING"].to_s.empty?
        return response(200, JSON.generate(@config))
      end
      unless env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == "/v1/#{@leaf}" && env["QUERY_STRING"].to_s.empty?
        return response(404, '{"error":"unsupported operation"}')
      end
      return response(413, '{"error":"request too large"}') if env["CONTENT_LENGTH"].to_i > MAX_REQUEST
      raw = env.fetch("rack.input").read(MAX_REQUEST + 1)
      return response(413, '{"error":"request too large"}') if raw.bytesize > MAX_REQUEST
      body = JSON.parse(raw)
      unless body.is_a?(Hash) && (body.keys - REQUEST_KEYS).empty? && body["model"] == @model &&
          body["messages"].is_a?(Array) && body["messages"].any? && body["messages"].all? { |message| text_message?(message) } &&
          (!body.key?("system") || text_content?(body["system"])) && !body["stream"]
        return response(422, '{"error":"unsupported review request"}')
      end
      response(200, forward(raw))
    rescue StandardError
      # Never relay provider errors or diagnostics containing source/API keys.
      response(502, '{"error":"provider unavailable"}')
    end

    private

    def forward(raw)
      # URL and authentication come only from operator configuration. Client
      # Host/Authorization headers, paths, redirects and proxy env are ignored.
      http = Net::HTTP.new(@uri.host, @uri.port, nil)
      http.use_ssl = @uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 240
      http.write_timeout = 30
      request = Net::HTTP::Post.new("#{@uri.path.delete_suffix('/')}/#{@leaf}")
      request["Content-Type"] = "application/json"
      if @provider != "anthropic"
        request["Authorization"] = "Bearer #{@key}"
      else
        request["x-api-key"] = @key
        request["anthropic-version"] = "2023-06-01"
      end
      request.body = raw
      output = String.new
      Timeout.timeout(280) do
        http.request(request) do |result|
          raise "provider refused" unless result.is_a?(Net::HTTPSuccess)
          result.read_body do |part|
            raise "oversized provider response" if output.bytesize + part.bytesize > MAX_RESPONSE
            output << part
          end
        end
      end
      parsed = JSON.parse(output)
      safe = if @provider == "anthropic"
        parsed["stop_reason"] == "end_turn" && parsed["content"].is_a?(Array) &&
          parsed["content"].all? { |block| %w[text thinking redacted_thinking].include?(block["type"]) }
      else
        parsed["choices"].is_a?(Array) && parsed["choices"].any? && parsed["choices"].all? do |choice|
          message = choice["message"]
          choice["finish_reason"] == "stop" && message.is_a?(Hash) && message["content"].is_a?(String) &&
            (message["tool_calls"].nil? || message["tool_calls"] == []) && message["function_call"].nil?
        end
      end
      raise ArgumentError, "incomplete or non-text model response" unless safe
      output
    end

    def text_message?(message)
      message.is_a?(Hash) && (message.keys - %w[role content]).empty? &&
        %w[system developer user].include?(message["role"]) && text_content?(message["content"])
    end

    def text_content?(content)
      content.is_a?(String) || (content.is_a?(Array) && content.all? do |block|
        block.is_a?(Hash) && (block.keys - %w[type text]).empty? && block["type"] == "text" && block["text"].is_a?(String)
      end)
    end

    def response(status, body)
      [ status, { "content-type" => "application/json", "content-length" => body.bytesize.to_s, "cache-control" => "no-store" }, [ body ] ]
    end
  end
end
