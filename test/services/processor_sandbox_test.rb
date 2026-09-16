require "test_helper"

class ProcessorSandboxTest < ActiveSupport::TestCase
  test "missing production processor never falls back into the app" do
    Dir.mktmpdir do |directory|
      assert_raises(Registry::UntrustedProcess::Failed) do
        Registry::ProcessorSandbox.call(:preview, "{}", timeout: 1, max_output_bytes: 1024,
          isolated: true, socket_path: File.join(directory, "missing.sock"))
      end
    end
  end

  test "deployment gives processors no app volumes or elevated privileges" do
    compose = YAML.safe_load_file(Rails.root.join("deploy/processors.compose.yml"), aliases: true)
    compose["services"].each do |role, service|
      assert service["read_only"]
      assert_equal [ "ALL" ], service["cap_drop"]
      assert_equal [ "no-new-privileges:true" ], service["security_opt"]
      assert_equal "1001:1000", service["user"]
      assert_operator service["pids_limit"], :<=, 64
      assert_nil service["ports"]
      assert_equal 0, service.dig("ulimits", "core")
      mounts = service["volumes"]
      if role == "gateway"
        assert_equal [ "/ai" ], mounts.map { |mount| mount["target"] }
        assert mounts.first["read_only"]
      else
        assert_equal [ "#{role}_socket:/run/processor" ], mounts
      end
    end
    assert_equal "none", compose.dig("services", "media", "network_mode")
    assert_equal [ "provider_link" ], compose.dig("services", "ai", "networks")
    assert_equal [ "127.0.0.1" ], compose.dig("services", "ai", "dns")
    assert compose.dig("networks", "provider_link", "internal")
    assert_equal "isolated", compose.dig("networks", "provider_link", "driver_opts", "com.docker.network.bridge.gateway_mode_ipv4")
    compose["volumes"].each_value do |volume|
      assert_equal "tmpfs", volume.dig("driver_opts", "type")
      assert_includes volume.dig("driver_opts", "o"), "size=1m"
    end
  end

  test "automatic Rails attachment processing cannot bypass processors" do
    assert_empty ActiveStorage.analyzers
    assert_empty ActiveStorage.previewers
  end

  test "workspace build context excludes local deployment secrets" do
    assert_includes Rails.root.join(".dockerignore").read.lines.map(&:strip), "/.kamal/"
  end
end
