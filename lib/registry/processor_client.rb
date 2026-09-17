require_relative "processor_protocol"

module Registry
  class ProcessorClient
    def self.call(kind, input, socket_path: nil, timeout: nil, max_output_bytes: nil)
      spec = ProcessorProtocol::SPECS.fetch(kind)
      raise ProcessorProtocol::Error, "processor input exceeds limit" if input.bytesize > spec[:input]
      exchange(socket_path || path(spec[:role]), spec[:code], input,
        timeout: timeout || spec[:timeout] + 30, limit: [ max_output_bytes || spec[:output], spec[:output] ].min)
    end

    def self.health(role, socket_path: nil)
      raise ArgumentError, "unknown processor role" unless %w[ai media].include?(role)
      JSON.parse(exchange(socket_path || "#{path(role)}.health", 0, "", timeout: 5, limit: 1024))
    end

    def self.path(role) = "/run/registry-processors/#{role}/processor.sock"

    def self.exchange(path, code, input, timeout:, limit:)
      socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
      connecting = socket.connect_nonblock(Socket.sockaddr_un(path), exception: false)
      if connecting == :wait_writable
        ProcessorProtocol::Frame.new(socket, timeout: 5).wait(:write)
        raise ProcessorProtocol::Error, "processor connection failed" unless socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int.zero?
      end
      frame = ProcessorProtocol::Frame.new(socket, timeout:)
      frame.write([ code, input.bytesize ].pack("CN"))
      frame.write(input)
      status, length = frame.read(5).unpack("CN")
      raise ProcessorProtocol::Error, "processor refused request" unless status.zero?
      raise ProcessorProtocol::Error, "processor output exceeds limit" if length > limit
      frame.read(length)
    rescue SystemCallError, IOError
      raise ProcessorProtocol::Error, "processor transport unavailable"
    ensure
      socket&.close
    end
    private_class_method :exchange, :path
  end
end
