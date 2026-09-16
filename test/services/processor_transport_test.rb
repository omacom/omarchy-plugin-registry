require "test_helper"

class ProcessorTransportTest < ActiveSupport::TestCase
  def with_server(role: "media", processor: ->(*) { raise "unexpected processing" })
    Dir.mktmpdir do |directory|
      path = File.join(directory, "processor.sock")
      listener = UNIXServer.new(path)
      server = Registry::ProcessorServer.new(role:, root: Rails.root.to_s, &processor)
      thread = Thread.new do
        socket = listener.accept
        server.handle(socket)
      ensure
        socket&.close
      end
      yield path
    ensure
      listener&.close
      thread&.kill unless thread&.join(1)
    end
  end

  test "fixed operation round trip preserves binary data" do
    with_server(processor: ->(_kind, input) { input.reverse }) do |path|
      assert_equal "\xff\0hello".b.reverse, Registry::ProcessorClient.call(:og, "\xff\0hello".b, socket_path: path)
    end
  end

  test "media service refuses AI without invoking a processor" do
    with_server do |path|
      assert_raises(Registry::ProcessorProtocol::Error) { Registry::ProcessorClient.call(:ai, "{}", socket_path: path) }
    end
  end

  test "unknown operation and excess input are rejected from their header" do
    [ [ 99, 0 ], [ 2, Registry::ProcessorProtocol::SPECS[:preview][:input] + 1 ] ].each do |header|
      with_server do |path|
        UNIXSocket.open(path) do |socket|
          frame = Registry::ProcessorProtocol::Frame.new(socket, timeout: 1)
          frame.write(header.pack("CN"))
          assert_equal [ 1, 0 ], frame.read(5).unpack("CN")
        end
      end
    end
  end

  test "processor failures expose neither diagnostics nor partial output" do
    with_server(processor: ->(*) { raise "synthetic-private-diagnostic" }) do |path|
      error = assert_raises(Registry::ProcessorProtocol::Error) { Registry::ProcessorClient.call(:og, "{}", socket_path: path) }
      assert_not_includes error.message, "synthetic-private-diagnostic"
    end
  end

  test "health reports only role and protocol" do
    with_server do |path|
      assert_equal({ "role" => "media", "protocol" => 1 }, Registry::ProcessorClient.health("media", socket_path: path))
    end
  end

  test "idle framing has a deadline" do
    left, right = UNIXSocket.pair
    assert_raises(Registry::ProcessorProtocol::Error) do
      Registry::ProcessorProtocol::Frame.new(left, timeout: 0.01).read(1)
    end
  ensure
    left&.close
    right&.close
  end
end
