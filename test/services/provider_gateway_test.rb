require "test_helper"

class ProviderGatewayTest < ActiveSupport::TestCase
  def gateway(**options)
    Registry::ProviderGateway.new(provider: "openai", endpoint: "https://model.example/v1", key: "synthetic-key", model: "fixture-model", **options)
  end

  def request(method: "POST", path: "/v1/chat/completions", query: "", body: { model: "fixture-model", messages: [] })
    { "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query, "rack.input" => StringIO.new(JSON.generate(body)) }
  end

  test "configuration exposes neither credentials nor upstream address" do
    status, _, body = gateway.call(request(method: "GET", path: "/configuration"))
    assert_equal 200, status
    assert_equal "fixture-model", JSON.parse(body.join)["model"]
    assert_not_includes body.join, "synthetic-key"
    assert_not_includes body.join, "model.example"
  end

  test "only the fixed completion operation is accepted" do
    [ request(method: "CONNECT"), request(path: "/other"), request(query: "extra=1") ].each do |env|
      assert_equal 404, gateway.call(env).first
    end
    [ { model: "another-model", messages: [] }, { model: "fixture-model", messages: [], tools: [] },
      { model: "fixture-model", messages: [], stream: true } ].each do |body|
      assert_equal 422, gateway.call(request(body:)).first
    end
  end

  test "plain HTTP needs explicit operator opt in" do
    assert_raises(ArgumentError) { gateway(endpoint: "http://model.example/v1") }
    assert gateway(endpoint: "http://model.example/v1", allow_http: true)
  end

  test "advertised oversized bodies are refused before reading" do
    env = request.merge("CONTENT_LENGTH" => (Registry::ProviderGateway::MAX_REQUEST + 1).to_s)
    assert_equal 413, gateway.call(env).first
  end

  test "relay uses operator credentials and path and does not forward client headers" do
    with_upstream do |port, received|
      env = request.merge("HTTP_AUTHORIZATION" => "client-placeholder", "HTTP_HOST" => "ignored.example")
      relay = gateway(endpoint: "http://127.0.0.1:#{port}/v1", allow_http: true)
      assert_equal 200, relay.call(env).first
      headers = received.pop
      assert_match(/POST \/v1\/chat\/completions /, headers)
      assert_match(/Authorization: Bearer synthetic-key/i, headers)
      assert_not_includes headers, "client-placeholder"
      assert_not_includes headers, "ignored.example"
    end
  end

  test "upstream redirects fail closed without relaying diagnostics" do
    with_upstream(status: "302 Found") do |port, _|
      relay = gateway(endpoint: "http://127.0.0.1:#{port}/v1", allow_http: true)
      status, _, body = relay.call(request)
      assert_equal 502, status
      assert_not_includes body.join, "synthetic-upstream-diagnostic"
    end
  end

  test "Anthropic uses its fixed path and server-owned authentication" do
    with_upstream do |port, received|
      relay = gateway(provider: "anthropic", endpoint: "http://127.0.0.1:#{port}/v1", allow_http: true)
      assert_equal 200, relay.call(request(path: "/v1/messages")).first
      headers = received.pop
      assert_match(/POST \/v1\/messages /, headers)
      assert_match(/X-Api-Key: synthetic-key/i, headers)
      assert_match(/Anthropic-Version: 2023-06-01/i, headers)
    end
  end

  test "OpenRouter configuration selects Muse and never exposes its key" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "openrouter_key"), "synthetic-openrouter-key\n")
      relay = Registry::ProviderGateway.from_directory(directory)
      status, _, body = relay.call(request(method: "GET", path: "/configuration"))
      assert_equal 200, status
      settings = JSON.parse(body.join)
      assert_equal "openai", settings["provider"]
      assert_equal "meta/muse-spark-1.3-contributor", settings["model"]
      assert_not_includes body.join, "synthetic-openrouter-key"
      assert_not_includes body.join, "https://openrouter.ai"

      File.write(File.join(directory, "model"), "explicit-model")
      relay = Registry::ProviderGateway.from_directory(directory)
      assert_equal "explicit-model", JSON.parse(relay.call(request(method: "GET", path: "/configuration")).last.join)["model"]
    end
  end

  test "OpenRouter refuses stale endpoint or other provider credentials" do
    %w[base_url openai_key anthropic_key].each do |name|
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, "openrouter_key"), "synthetic-openrouter-key")
        File.write(File.join(directory, name), "stale-provider-setting")
        assert_raises(ArgumentError) { Registry::ProviderGateway.from_directory(directory) }
      end
    end
  end

  test "OpenRouter relay uses its API path and server-owned bearer key" do
    with_upstream do |port, received|
      relay = gateway(provider: "openrouter", endpoint: "http://127.0.0.1:#{port}/api/v1", allow_http: true)
      assert_equal 200, relay.call(request).first
      headers = received.pop
      assert_match(/POST \/api\/v1\/chat\/completions /, headers)
      assert_match(/Authorization: Bearer synthetic-key/i, headers)
      refute_match(/X-Api-Key:/i, headers)
    end
  end

  test "review requests cannot enable OpenRouter plugins or change routing" do
    %w[plugins models route provider].each do |field|
      body = { model: "fixture-model", messages: [], field => [] }
      assert_equal 422, gateway.call(request(body:)).first
    end
  end

  private

  def with_upstream(status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    thread = Thread.new do
      socket = server.accept
      headers = String.new
      headers << socket.gets until headers.end_with?("\r\n\r\n")
      socket.read(headers[/Content-Length: (\d+)/i, 1].to_i)
      received << headers
      body = "synthetic-upstream-diagnostic"
      socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nLocation: /elsewhere\r\nConnection: close\r\n\r\n#{body}")
    ensure
      socket&.close
    end
    yield server.addr[1], received
  ensure
    server&.close
    thread&.kill unless thread&.join(1)
  end
end
