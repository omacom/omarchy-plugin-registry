module Registry
  # In production the boundary is a separate container, reached only over a
  # Unix socket. No Docker socket, nested namespaces, or in-app fallback.
  class ProcessorSandbox
    def self.call(kind, input, timeout:, max_output_bytes:, isolated: Rails.env.production?, socket_path: nil)
      if isolated
        ProcessorClient.call(kind, input, timeout: timeout + 30, max_output_bytes:, socket_path:)
      else
        spec = ProcessorProtocol::SPECS.fetch(kind)
        UntrustedProcess.call([ RbConfig.ruby, Rails.root.join("script", spec[:script]).to_s ], input, timeout:, max_output_bytes:)
      end
    rescue ProcessorProtocol::Error => e
      raise UntrustedProcess::Failed, e.message
    end
  end
end
