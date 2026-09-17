module Registry
  # No image parser runs here. The standalone subprocess handles both header
  # validation and decoding; production additionally requires the sandbox.
  class PreviewImage
    class InvalidPreview < StandardError; end
    MAX_INPUT_BYTES = 10.megabytes
    MAX_OUTPUT_BYTES = 24.megabytes

    def self.validate!(bytes, name:)
      invoke("validate", bytes, name:)
      true
    end

    def self.process(bytes, name:)
      result = invoke("process", bytes, name:)
      card = decode_rendition(result.fetch("card"))
      detail = decode_rendition(result.fetch("detail"))
      meta = result.fetch("meta")
      unless meta.is_a?(Hash) && [ true, false ].include?(meta["animated"]) &&
          valid_dimensions?(meta.slice("source_width", "source_height").transform_keys { |key| key.delete_prefix("source_") }) &&
          valid_dimensions?(meta["card"], width: 720, height: 720) &&
          valid_dimensions?(meta["detail"], width: 1600, height: 1200)
        raise InvalidPreview, "invalid preview processor metadata"
      end
      { card:, detail:, meta: meta.slice("animated", "source_width", "source_height", "card", "detail").merge("source" => name) }
    rescue KeyError, ArgumentError, TypeError
      raise InvalidPreview, "invalid preview processor output"
    end

    # Treat processor output as data too, without decoding images in Rails.
    def self.decode_rendition(encoded)
      bytes = Base64.strict_decode64(encoded)
      unless bytes.bytesize >= 12 && bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP" &&
          bytes.byteslice(4, 4).unpack1("V") == bytes.bytesize - 8
        raise InvalidPreview, "invalid preview rendition"
      end
      bytes
    end

    def self.valid_dimensions?(dimensions, width: 40_000_000, height: 40_000_000)
      dimensions.is_a?(Hash) && dimensions.keys.sort == %w[height width] &&
        dimensions["width"].is_a?(Integer) && dimensions["width"].between?(1, width) &&
        dimensions["height"].is_a?(Integer) && dimensions["height"].between?(1, height)
    end

    def self.invoke(action, bytes, name:)
      raise InvalidPreview, "preview exceeds 10MB" if bytes.bytesize > MAX_INPUT_BYTES
      payload = JSON.generate({ action:, name:, bytes: Base64.strict_encode64(bytes) })
      output = ProcessorSandbox.call(:preview, payload,
        timeout: 45, max_output_bytes: MAX_OUTPUT_BYTES)
      result = JSON.parse(output)
      raise InvalidPreview, "invalid preview processor output" unless result.is_a?(Hash)
      raise InvalidPreview, result["error"].to_s.first(300) if result["error"]
      raise InvalidPreview, "preview validation did not complete" unless result["valid"] == true
      result
    rescue UntrustedProcess::Failed, JSON::ParserError
      raise InvalidPreview, "preview processor unavailable; image was not accepted"
    end
    private_class_method :invoke, :decode_rendition, :valid_dimensions?
  end
end
