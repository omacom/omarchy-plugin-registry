require "test_helper"

class UntrustedProcessTest < ActiveSupport::TestCase
  def run_processor(source, input: "", timeout: 5, limit: 1024)
    Registry::UntrustedProcess.call([ RbConfig.ruby, "-e", source ], input,
      timeout:, max_output_bytes: limit)
  end

  test "passes input but not inherited application environment" do
    original = ENV["REGISTRY_PROCESS_TEST_SECRET"]
    ENV["REGISTRY_PROCESS_TEST_SECRET"] = "synthetic-sentinel"
    output = run_processor('abort if ENV.key?("REGISTRY_PROCESS_TEST_SECRET"); print STDIN.read.upcase', input: "hello")
    assert_equal "HELLO", output
  ensure
    ENV["REGISTRY_PROCESS_TEST_SECRET"] = original
  end

  test "nonzero exits fail without exposing processor diagnostics" do
    error = assert_raises(Registry::UntrustedProcess::Failed) do
      run_processor('STDERR.write("synthetic-private-diagnostic"); exit 7')
    end
    assert_match(/unsuccessfully/, error.message)
    assert_not_includes error.message, "synthetic-private-diagnostic"
  end

  test "bounded output fails promptly even when a child is blocked writing" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Registry::UntrustedProcess::Failed) do
      run_processor('STDOUT.write("a" * 100_000)', limit: 128, timeout: 10)
    end
    assert_match(/exceeds limit/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  test "closed output does not exempt a child from its lifetime bound" do
    error = assert_raises(Registry::UntrustedProcess::Failed) do
      run_processor("STDOUT.close; sleep 10", timeout: 1)
    end
    assert_match(/timed out/, error.message)
  end

  test "missing processor fails without a fallback" do
    assert_raises(Registry::UntrustedProcess::Failed) do
      Registry::UntrustedProcess.call([ Rails.root.join("tmp/nonexistent-review-processor").to_s ], "",
        timeout: 1, max_output_bytes: 128)
    end
  end
end
