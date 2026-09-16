module Registry
  # A conservative tripwire, not a proof that prose cannot influence a model.
  # Matches in docs, comments, filenames and metadata are never exempted.
  module PromptInjection
    PATTERNS = {
      "instruction override" => /\b(?:ignore|disregard|forget|override|bypass)\b.{0,100}\b(?:previous|prior|above|system|developer|review|security)\b.{0,60}\b(?:instructions?|prompts?|rules?|checks?|policy)\b/im,
      "forged message role" => /<\|(?:im_start|start_header_id)\|>|\[INST\]|<<SYS>>|<\/?(?:system|developer|assistant)(?:\s[^>]*|)>/i,
      "reviewer-directed instructions" => /\b(?:instructions?\s+(?:to|for)|attention|dear|note\s+to)\s+(?:(?:the|ai|automated|security|code|llm)\s+)*(?:reviewer|assistant|agent|model)\b/i,
      "forced review outcome" => /\b(?:return|output|respond(?:\s+with)?|emit)\s+(?:only\s+|exactly\s+)?\{.{0,120}["']verdict["']\s*:\s*["']pass["']/im,
      "suppressed security findings" => /\b(?:do\s+not|don't|never)\s+(?:report|flag|mention|disclose)\b.{0,100}\b(?:vulnerabilit\w*|security|findings?|injection|malicious|suspicious)\b/im,
      "false approval authority" => /\b(?:system|developer|admin|maintainer)\s+(?:message|override|instruction)\s*:.{0,160}\b(?:approve|pass|ignore|safe)\b/im
    }.freeze

    def self.detect(text)
      normalized = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        .gsub(/\\u([0-9a-f]{4})/i) { [ $1.to_i(16) ].pack("U").scrub }
        .unicode_normalize(:nfkc).gsub(/\p{Cf}/, "")
      PATTERNS.find { |_label, pattern| pattern.match?(normalized) }&.first
    end
  end
end
