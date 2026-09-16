require "open3"
require "tmpdir"

module Registry
  # Bounded pipes, process lifetime, and resource use for trusted processors
  # handling untrusted data. Container isolation is configured separately.
  class UntrustedProcess
    class Failed < StandardError; end

    def self.call(command, input, timeout:, max_output_bytes:, memory_bytes: 2 * 1024**3, environment: {})
      environment = { "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8", "HOME" => Dir.tmpdir,
                      "VIPS_CONCURRENCY" => "1" }.merge(environment)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      Open3.popen3(environment, *Array(command), unsetenv_others: true, pgroup: true,
        rlimit_core: 0, rlimit_as: memory_bytes, rlimit_cpu: timeout) do |stdin, stdout, stderr, waiter|
        threads = []
        threads << Thread.new do
          stdin.write(input)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          stdin.close rescue nil
        end
        reader = Thread.new do
          stdout.read(max_output_bytes + 1)
        rescue IOError
          nil
        end
        threads << reader
        threads << Thread.new do
          nil while stderr.read(65_536)
        rescue IOError
          nil
        end
        begin
          # Observe the bounded reader first: an overproducing child must be
          # stopped immediately, not left blocked on a full pipe until timeout.
          raise Failed, "processor timed out" unless reader.join(timeout)
          output = reader.value.to_s
          raise Failed, "processor output exceeds limit" if output.bytesize > max_output_bytes
          remaining = [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max
          raise Failed, "processor timed out" unless waiter.join(remaining)
          raise Failed, "processor exited unsuccessfully" unless waiter.value.success?
          output
        ensure
          Process.kill("KILL", -waiter.pid) rescue nil
          [ stdin, stdout, stderr ].each { |io| io.close rescue nil }
          threads.each { |thread| thread.kill unless thread.join(1) }
        end
      end
    rescue SystemCallError => e
      raise Failed, "processor unavailable (#{e.class})"
    end
  end
end
