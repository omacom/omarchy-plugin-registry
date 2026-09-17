require "socket"
require "json"

module Registry
  # Fixed operations, binary framing, and deadlines; never deserialize Ruby
  # objects or accept script names, commands, paths, or URLs over this channel.
  module ProcessorProtocol
    class Error < StandardError; end
    SPECS = {
      ai: { code: 1, role: "ai", script: "ai_review_adapter", input: 80 * 1024**2, output: 1024**2, timeout: 900 },
      preview: { code: 2, role: "media", script: "preview_processor", input: 14 * 1024**2, output: 24 * 1024**2, timeout: 45 },
      og: { code: 3, role: "media", script: "og_card_processor", input: 14 * 1024**2, output: 4 * 1024**2, timeout: 45 }
    }.transform_values(&:freeze).freeze
    VERSION = 1

    class Frame
      def initialize(io, timeout:)
        @io = io
        @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      end

      def read(length)
        bytes = String.new(encoding: Encoding::BINARY)
        while bytes.bytesize < length
          wait(:read)
          part = @io.read_nonblock([ length - bytes.bytesize, 65_536 ].min, exception: false)
          next if part == :wait_readable
          raise Error, "processor connection closed" unless part
          bytes << part
        end
        bytes
      end

      def write(bytes)
        offset = 0
        while offset < bytes.bytesize
          wait(:write)
          written = @io.write_nonblock(bytes.byteslice(offset, 65_536), exception: false)
          next if written == :wait_writable
          offset += written
        end
      end

      def wait(direction)
        remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "processor transport timed out" unless remaining.positive?
        ready = direction == :read ? IO.select([ @io ], nil, nil, remaining) : IO.select(nil, [ @io ], nil, remaining)
        raise Error, "processor transport timed out" unless ready
      end
    end
  end
end
