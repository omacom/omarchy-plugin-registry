require "net/http"
require "json"

module Registry
  module AiGateway
    URL = "http://registry-ai-gateway:8080"

    def self.configuration
      http = Net::HTTP.new("registry-ai-gateway", 8080, nil)
      http.open_timeout = http.read_timeout = 5
      raw = String.new
      http.request(Net::HTTP::Get.new("/configuration")) do |response|
        raise ArgumentError, "gateway unavailable" unless response.is_a?(Net::HTTPSuccess)
        response.read_body do |part|
          raise ArgumentError, "oversized gateway configuration" if raw.bytesize + part.bytesize > 16_384
          raw << part
        end
      end
      settings = JSON.parse(raw)
      unless settings.is_a?(Hash) && %w[openai anthropic].include?(settings["provider"]) &&
          settings["model"].is_a?(String) && settings["model"].length.between?(1, 200) &&
          settings["effort"].is_a?(String) && settings["effort"].length.between?(1, 20) &&
          settings["chunk_chars"].is_a?(Integer) && settings["chunk_chars"].between?(1024, 120_000)
        raise ArgumentError, "invalid gateway configuration"
      end
      settings
    end
  end
end
