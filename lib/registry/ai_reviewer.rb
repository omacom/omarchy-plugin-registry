require "json"
require_relative "prompt_injection"

module Registry
  # Pure, tool-less review orchestration, also used by the standalone adapter.
  # The caller supplies model I/O. Source and model responses are always data.
  class AiReviewer
    VERSION = "2"
    PASSES = %w[instruction_integrity security].freeze
    CHUNK_CHARS = 120_000
    MAX_CHUNKS = 40
    DEADLINE_SECONDS = 840

    def initialize(request, chunk_chars: CHUNK_CHARS, max_chunks: MAX_CHUNKS,
      deadline_seconds: DEADLINE_SECONDS, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, &model_call)
      @request = request
      @chunk_chars = chunk_chars
      @max_chunks = max_chunks
      @clock = clock
      @deadline = clock.call + deadline_seconds
      @model_call = model_call
    end

    def review
      unless @request.is_a?(Hash) && @request["files"].is_a?(Hash) && @chunk_chars.positive?
        return result("flag", [ "invalid review envelope" ])
      end

      if (reason = PromptInjection.detect(JSON.generate(@request)))
        return result("flag", [ "possible prompt injection: #{reason}; model review stopped" ])
      end
      files = @request.fetch("files")
      assets = Array(@request["verified_assets"])
      gaps = Array(@request["incomplete_files"]) - assets
      return result("flag", [ "incomplete source coverage: #{gaps.first(10).join(', ')}" ]) if gaps.any?

      parts = []
      files.sort.each do |path, content|
        next if assets.include?(path)
        unless content.is_a?(String) && content.valid_encoding? && !content.include?("\0")
          return result("flag", [ "unreviewable source: #{path}" ])
        end
        # No filename, minification, or line-length exemption. Split large
        # files without losing any characters, including the final tail.
        offset = 0
        while offset < content.length
          piece = content[offset, @chunk_chars]
          parts << { "path" => path, "offset" => offset, "total_chars" => content.length, "content" => piece }
          offset += piece.length
        end
      end

      chunks = [ [] ]
      size = 0
      parts.each do |part|
        if chunks.last.any? && size + part["content"].length > @chunk_chars
          chunks << []
          size = 0
        end
        chunks.last << part
        size += part["content"].length
      end
      if chunks.size > @max_chunks
        return result("flag", [ "source exceeds the complete-review budget" ])
      end

      @passes = PASSES.map { |name| { "id" => name, "verdict" => "skipped", "chunks_completed" => 0, "chunks_total" => chunks.size } }
      @source_files = files.keys - assets
      @asset_files = assets
      context = @request.reject { |key, _| key == "files" }
      @passes.each do |pass|
        chunks.each_with_index do |chunk, index|
          return result("flag", [ "deadline reached before review completed" ]) if @clock.call >= @deadline
          body = { "chunk" => index + 1, "total_chunks" => chunks.size, "context" => context,
                   "source_parts" => chunk,
                   "note" => "Parts include offsets within each file. Flag uncertainty about behavior or data flow across parts; never assume omitted context is safe." }
          pass["verdict"] = "running"
          verdict = self.class.parse_verdict(@model_call.call(JSON.generate(body), pass.fetch("id")))
          pass["chunks_completed"] += 1
          if verdict["verdict"] == "flag"
            pass["verdict"] = "flag"
            return result("flag", verdict.fetch("reasons"))
          end
        end
        pass["verdict"] = "pass"
      end
      return result("flag", [ "review exceeded its deadline" ]) if @clock.call >= @deadline

      result("pass", [], complete: true, chunks: chunks.size)
    rescue StandardError => e
      # Never copy provider errors/model text into logs or a public reason:
      # they can contain unpublished source or provider credentials.
      result("flag", [ "review could not complete (#{e.class})" ])
    end

    def self.parse_verdict(text)
      parsed = JSON.parse(text, allow_duplicate_key: false)
      unless parsed.is_a?(Hash) && (parsed.keys - %w[verdict reasons]).empty? &&
          %w[pass flag].include?(parsed["verdict"]) && parsed["reasons"].is_a?(Array) &&
          parsed["reasons"].size <= 20 && parsed["reasons"].all? { |r| r.is_a?(String) && r.length.between?(1, 600) } &&
          (parsed["verdict"] == "pass" ? parsed["reasons"].empty? : parsed["reasons"].any?)
        raise ArgumentError, "invalid model verdict schema"
      end
      parsed
    end

    private

    def result(verdict, reasons, complete: false, chunks: 0)
      @passes&.each { |pass| pass["verdict"] = "failed" if pass["verdict"] == "running" }
      { "verdict" => verdict, "reasons" => reasons.uniq.first(20), "reviewer_version" => VERSION,
        "coverage" => { "complete" => complete, "archive_sha256" => @request.is_a?(Hash) ? @request["sha256"] : nil,
                        "chunks" => chunks, "passes" => @passes || [],
                        "source_files" => @source_files&.size || 0, "asset_files" => @asset_files&.size || 0 } }
    end
  end
end
