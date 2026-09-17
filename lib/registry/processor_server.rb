require_relative "processor_protocol"
require_relative "untrusted_process"

module Registry
  class ProcessorServer
    def initialize(role:, root:, health_check: nil, &processor)
      raise ArgumentError, "unknown role" unless %w[ai media].include?(role)
      @role, @root = role, root
      @processor = processor || method(:process)
      @health_check = health_check
    end

    # Worker count is fixed at service startup. Each connection has one bounded
    # operation; there is no asynchronous job API or unbounded thread spawning.
    def serve(socket_path, workers:)
      server = listener(socket_path)
      health_server = listener("#{socket_path}.health")
      health_thread = Thread.new do
        loop do
          socket = health_server.accept
          handle(socket, health_only: true)
        ensure
          socket&.close
        end
      end
      processing_threads = Array.new(workers) do
        Thread.new do
          loop do
            socket = server.accept
            handle(socket)
          ensure
            socket&.close
          end
        end
      end
      (processing_threads + [ health_thread ]).each(&:join)
    ensure
      server&.close
      health_server&.close
    end

    def handle(socket, health_only: false)
      frame = ProcessorProtocol::Frame.new(socket, timeout: 30)
      code, length = frame.read(5).unpack("CN")
      raise ProcessorProtocol::Error, "not a health operation" if health_only && !code.zero?
      if code.zero?
        raise ProcessorProtocol::Error, "invalid health request" unless length.zero?
        @health_check&.call
        output = JSON.generate({ protocol: ProcessorProtocol::VERSION, role: @role })
      else
        kind, spec = ProcessorProtocol::SPECS.find { |_, value| value[:code] == code }
        raise ProcessorProtocol::Error, "invalid processor operation" unless spec && spec[:role] == @role && length <= spec[:input]
        output = @processor.call(kind, frame.read(length))
        raise ProcessorProtocol::Error, "oversized processor response" if output.bytesize > spec[:output]
      end
      reply = ProcessorProtocol::Frame.new(socket, timeout: 15)
      reply.write([ 0, output.bytesize ].pack("CN"))
      reply.write(output)
    rescue StandardError
      # Do not relay exception messages, source, environment, or provider data.
      ProcessorProtocol::Frame.new(socket, timeout: 1).write([ 1, 0 ].pack("CN")) rescue nil
    end

    private

    def listener(path)
      File.unlink(path) if File.socket?(path)
      UNIXServer.new(path).tap do |server|
        File.chmod(0o660, path)
        server.listen(8)
      end
    end

    def process(kind, input)
      spec = ProcessorProtocol::SPECS.fetch(kind)
      environment = kind == :ai ? { "REGISTRY_AI_GATEWAY" => "http://registry-ai-gateway:8080" } : {}
      UntrustedProcess.call([ RbConfig.ruby, File.join(@root, "script", spec[:script]) ], input,
        timeout: spec[:timeout], max_output_bytes: spec[:output], environment:)
    end
  end
end
