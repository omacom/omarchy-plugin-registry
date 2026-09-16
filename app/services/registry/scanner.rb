module Registry
  # Deterministic scanning: GuardDog-style rules tuned for the Omarchy stack
  # (bash + QML/JS), plus metadata anomalies. Runs on every version, every time.
  #
  # Severities:
  #   :fail — rejected automatically, no human in the loop
  #   :flag — quarantined for the admin queue
  class Scanner
    Finding = Struct.new(:rule, :severity, :file, :detail) do
      def as_json(*) = { "rule" => rule, "severity" => severity.to_s, "file" => file, "detail" => detail }
    end

    # Any TEXT source ships scanned, whatever the language — the generic rules
    # (curl-pipe, eval, dead-drop hosts, credential paths…) read fine across
    # languages, and a blind "binary-payload" flag on a .rs helper just floods
    # the queue. Genuinely binary content behind these still flags via
    # binary-in-text-extension. (.xbm is a C-syntax text image format.)
    TEXT_EXTENSIONS = %w[.qml .js .mjs .sh .bash .json .md .txt .yml .yaml .toml .conf .css .svg .xml .html .ini .desktop
                         .py .rules .install .rs .ts .tsx .lua .rb .go .c .cpp .cc .h .hpp
                         .service .timer .socket .jsonc .json5 .lock .license .xbm .vim .fish .nu .zsh .env .example .tmpl .template].freeze

    # Asset types eligible for full-byte signature/marker checks instead of
    # text rules. These checks reduce risk, not prove the bytes harmless.
    ASSET_MAGIC = {
      ".png" => [ "\x89PNG".b ],
      ".jpg" => [ "\xFF\xD8\xFF".b ],
      ".jpeg" => [ "\xFF\xD8\xFF".b ],
      ".gif" => [ "GIF87a".b, "GIF89a".b ],
      ".webp" => [ "RIFF".b ],
      ".ico" => [ "\x00\x00\x01\x00".b, "\x00\x00\x02\x00".b ],
      ".ttf" => [ "\x00\x01\x00\x00".b, "true".b ],
      ".otf" => [ "OTTO".b ],
      ".woff" => [ "wOFF".b ],
      ".woff2" => [ "wOF2".b ],
      ".mp3" => [ "ID3".b, "\xFF\xFB".b, "\xFF\xF3".b, "\xFF\xF2".b ],
      ".wav" => [ "RIFF".b ],
      ".ogg" => [ "OggS".b ],
      ".oga" => [ "OggS".b ],
      ".opus" => [ "OggS".b ]
    }.freeze

    # ISO base-media containers carry their magic at offset 4 ("ftyp"), not 0.
    OFFSET_FTYP_EXTS = %w[.mp4 .m4a .m4v .mov].freeze

    # Extensions that promise compiled/opaque content — never eligible for the
    # unknown-type text fallback, whatever their byte statistics say.
    BINARY_EXTENSIONS = %w[.so .o .a .dylib .dll .exe .bin .pyc .pyo .qsb .dat .db .sqlite .sqlite3 .part].freeze

    # Bidi override/embedding controls \u2014 the Trojan Source attack: they reorder
    # how code RENDERS to a reviewer. No data file needs them either; always
    # malicious-shaped in code.
    BIDI_UNICODE = /[\u202A-\u202E\u2066-\u2069]/
    # Zero-width and directional-mark codepoints. Suspicious in code (the
    # GlassWorm hiding trick) but LEGITIMATE in internationalized data: ZWJ
    # sequences in emoji tables, ZWNJ in Persian/Arabic orthography, LRM/RLM
    # in RTL corpora. A leading BOM is stripped before scanning; the rest
    # flags for judgment instead of auto-rejecting a prayer-times plugin over
    # its own scripture strings.
    INVISIBLE_UNICODE = /[\u200B-\u200F\u2060\uFEFF]/

    SUSPICIOUS_HOSTS = %w[
      pastebin.com paste.ee hastebin.com rentry.co
      discord.com/api/webhooks discordapp.com/api/webhooks
      api.telegram.org transfer.sh oshi.at temp.sh
    ].freeze

    VERSION = "2"
    CHECK_LABELS = {
      "file-types" => "File types and readable source",
      "scan-truncated" => "Complete deterministic source coverage",
      "polyglot-executable" => "Binary asset signatures and embedded payloads",
      "prompt-injection" => "Prompt-injection tripwires",
      "bidi-unicode" => "Bidirectional source hiding",
      "invisible-unicode" => "Invisible source characters",
      "curl-pipe-shell" => "Downloaded shell execution",
      "base64-decode-exec" => "Base64 decode-and-execute",
      "eval-construct" => "Dynamic code evaluation",
      "raw-ip-url" => "Raw IP network destinations",
      "suspicious-host" => "Suspicious network hosts",
      "credential-paths" => "Credential and key access",
      "hardcoded-private-key" => "Embedded private keys",
      "hardcoded-token" => "Embedded credential tokens",
      "python-decode-exec" => "Decoded Python execution",
      "shell-history-tamper" => "Shell history tampering",
      "home-write" => "Writes outside package storage",
      "system-write" => "Writes to system paths",
      "embedded-shebang" => "Embedded script payloads",
      "obfuscation-entropy" => "Packed or obfuscated text",
      "dormant-plugin-update" => "Dormant release history"
    }.freeze

    attr_reader :findings

    def initialize(tarball, plugin: nil)
      @tarball = tarball
      @plugin = plugin
      @findings = []
      @checked_rules = {}
    end

    def scan
      @tarball.contents.each do |path, content|
        record_check("file-types", path)
        record_check("scan-truncated", path)
        record_check("prompt-injection", path)
        if (reason = PromptInjection.detect(path)) || (text_like?(content) && (reason = PromptInjection.detect(content)))
          findings << Finding.new("prompt-injection", :flag, path, "possible prompt injection: #{reason}")
        end
        if scannable?(path, content)
          if text_like?(content)
            text = content.dup.force_encoding(Encoding::UTF_8)
            text = text.scrub unless text.valid_encoding?
            # Docs legitimately carry RTL/formatting marks — they flag for a
            # human instead of auto-rejecting; CODE never needs them.
            # The manifest also contains prose; it still gets behavior rules.
            docs = %w[.md .txt].include?(File.extname(path).downcase) ||
              DOC_FILENAMES.include?(File.basename(path, ".*").downcase) ||
              File.basename(path) == "manifest.json"
            # Documentation can be loaded as code too. Its name only affects
            # Unicode severity, never whether behavior rules run.
            scan_file(path, text.delete_prefix("\uFEFF"), strict: !docs)
          else
            # Binary bytes hiding behind a code extension: pattern rules can't
            # see into it, so a human must.
            findings << Finding.new("binary-in-text-extension", :flag, path,
              "content is binary despite a #{File.extname(path)} extension")
          end
        elsif genuine_asset?(path, content)
          record_check("polyglot-executable", path)
          # Polyglots: a valid asset header with executable content behind it
          # still runs if invoked. The inspector computed payload markers over
          # the FULL bytes (past the retention window), which is the check
          # that matters; text-pattern rules are NOT run over binary \u2014 random
          # compressed bytes match zero-width-unicode and shell regexes by
          # sheer statistics, and that noise was quarantining plugins for
          # their screenshots.
          Array(@tarball.payload_markers[path]).each do |marker|
            findings << Finding.new("polyglot-executable", :flag, path,
              "asset contains an embedded executable payload (#{marker})")
          end
        elsif text_like?(content) && Array(@tarball.payload_markers[path]).empty? &&
            !BINARY_EXTENSIONS.include?(File.extname(path).downcase)
          # Unknown extension (or none) but plainly readable text \u2014 a .kt
          # helper, a shader, an htoprc, a LICENSE-MIT. Scan it as code with
          # the full strict ruleset; "binary-payload" on a text file was just
          # a lie that flooded the queue. Never for executable-marked bytes or
          # extensions that PROMISE binary \u2014 a mostly-ASCII .so is still a .so.
          text = content.dup.force_encoding(Encoding::UTF_8)
          text = text.scrub unless text.valid_encoding?
          scan_file(path, text.delete_prefix("\ufeff"))
        else
          # Genuinely unscannable non-asset bytes ship anyway \u2014 never unreviewed.
          findings << Finding.new("binary-payload", :flag, path,
            "file is not a scannable type or a recognizable asset (#{File.extname(path).presence || 'no extension'}); a human must look")
        end
      end
      # Reviewed bytes must be ALL the bytes: anything past the per-file scan
      # cap escaped analysis, so it goes to a human too. Magic-verified assets
      # are exempt \u2014 their full bytes were checked for executable payload
      # markers at inspection, and "screenshot bigger than 512KB" is the
      # normal case, not an anomaly.
      @tarball.truncated.each do |path|
        next if genuine_asset?(path, @tarball.contents[path])
        findings << Finding.new("scan-truncated", :flag, path,
          "file exceeds the #{Registry::TarballInspector::MAX_SCAN_BYTES / 1.kilobyte}KB scan window \u2014 not fully analyzed")
      end
      scan_metadata
      findings
    end

    def verdict
      return :fail if findings.any? { |f| f.severity == :fail }
      return :flag if findings.any? { |f| f.severity == :flag }
      :pass
    end

    # Persist what actually ran. Older reviews cannot reconstruct passes from
    # an empty findings array, and inapplicable asset checks are not "passed".
    def checks
      CHECK_LABELS.filter_map do |rule, label|
        next unless @checked_rules.key?(rule) || rule == "polyglot-executable"
        matching = if rule == "file-types"
          findings.select { |f| %w[binary-payload binary-in-text-extension].include?(f.rule) }
        else
          findings.select { |f| f.rule == rule }
        end
        status = if !@checked_rules.key?(rule)
          "not_applicable"
        elsif matching.any? { |f| f.severity == :fail }
          "failed"
        elsif matching.any?
          "flagged"
        else
          "passed"
        end
        { "id" => rule, "name" => label, "status" => status,
          "files_checked" => @checked_rules.fetch(rule, []).size, "findings_count" => matching.size }
      end
    end

    # These bytes received the full-byte asset checks; all other content must
    # be reviewed as source or explicitly quarantined. Never trust an extension
    # alone when deciding what the AI may omit.
    def verified_assets
      @tarball.files.select do |path|
        genuine_asset?(path, @tarball.contents.fetch(path)) && Array(@tarball.payload_markers[path]).empty?
      end
    end

    private

    # Prose files where RTL/formatting marks are legitimate — invisible
    # unicode flags for a human here instead of auto-rejecting.
    DOC_FILENAMES = %w[readme license licence copying notice authors changelog contributing codeowners].freeze

    # qmldir is the QML module definition file — it ships in virtually every
    # Quattro plugin and MUST scan as text, not flag as an opaque payload.
    # The dotfiles/build files are ordinary repo furniture; scanning them with
    # the full STRICT ruleset (they are code, not prose) beats sending every
    # plugin that has a .gitignore to a human.
    PLAIN_FILENAMES = (DOC_FILENAMES + %w[qmldir makefile dockerfile pkgbuild
                         .gitignore .gitattributes .editorconfig .srcinfo]).freeze

    # RIFF is a container: the subtype at offset 8 must match the extension,
    # or any RIFF-prefixed payload would pass as .webp/.wav.
    RIFF_SUBTYPES = { ".webp" => "WEBP", ".wav" => "WAVE" }.freeze

    def genuine_asset?(path, content)
      ext = File.extname(path).downcase
      return content.byteslice(4, 4).to_s.b == "ftyp" if OFFSET_FTYP_EXTS.include?(ext)
      magics = ASSET_MAGIC[ext]
      return false if magics.nil?
      head = content.byteslice(0, 16).to_s.b
      return false unless magics.any? { |magic| head.start_with?(magic) }
      if (subtype = RIFF_SUBTYPES[ext])
        return head.byteslice(8, 4) == subtype
      end
      true
    end

    # Valid UTF-8 with a high printable ratio — what a real source file looks like.
    def text_like?(content)
      sample = content.byteslice(0, 8.kilobytes).to_s.dup.force_encoding(Encoding::UTF_8)
      return false unless sample.valid_encoding?
      return true if sample.empty?
      printable = sample.count("\t\n\r -~") + sample.chars.count { |c| c.ord > 127 }
      printable.fdiv(sample.length) > 0.9
    end

    def scannable?(path, content)
      ext = File.extname(path).downcase
      return true if TEXT_EXTENSIONS.include?(ext)
      return true if PLAIN_FILENAMES.include?(File.basename(path, ".*").downcase)
      return true if ext.empty? && content.byteslice(0, 256).to_s.start_with?("#!")
      false
    end

    # Every shipped text file receives behavioral checks, including docs and
    # fixtures. False positives need judgment, not author-controlled exemptions.
    def scan_file(path, text, entropy: true, strict: true)
      check path, text, "bidi-unicode", strict ? :fail : :flag, BIDI_UNICODE,
        "bidirectional override characters (code renders differently than it executes)"
      check path, text, "invisible-unicode", :flag, INVISIBLE_UNICODE,
        "zero-width or directional-mark Unicode characters (legitimate in i18n data, code-hiding in code)"
      check path, text, "curl-pipe-shell", :flag, %r{\b(curl|wget)\b[^|\n;]*\|\s*(sudo\s+)?(?:/[\w/]*/)?(ba|z|da)?sh\b},
        "pipes a remote download straight into a shell"
      check path, text, "base64-decode-exec", :flag, /base64\s+(-d|--decode)[^\n]*\|\s*(sudo\s+)?\w*sh\b|eval.{0,40}base64|atob\s*\([^)]*\).{0,40}(eval|Function)/m,
        "decodes base64 and executes it"
      check path, text, "eval-construct", :flag, /\beval\s*\(|new\s+Function\s*\(/,
        "dynamic code evaluation"
      # Loopback is the plugin's own machine (Hyprland IPC, local daemons) —
      # not the dead-drop pattern this rule hunts. Everything else, including
      # RFC1918, still flags: a LAN default in shipped code deserves a look.
      check path, text, "raw-ip-url", :flag, %r{https?://(?!127\.|0\.0\.0\.0|\[?::1\]?)\d{1,3}(\.\d{1,3}){3}},
        "network call to a raw IP address"
      check path, text, "suspicious-host", :flag, /#{SUSPICIOUS_HOSTS.map { |h| Regexp.escape(h) }.join("|")}/,
        "contacts a paste site, webhook, or dead-drop service"
      check path, text, "credential-paths", :flag,
        %r{(\$\{?HOME\}?|~)/\.(ssh|gnupg|aws|config/gh|mozilla)\b|\.ssh/id_|\.local/share/keyrings|/etc/shadow\b|\.config/(google-chrome|chromium|BraveSoftware)},
        "touches credential or key storage"
      # A PEM header or a fixed-format token in shipped code is always worth a
      # human look — these formats are FP-resistant (a scanner plugin carrying
      # the TOKEN REGEX as a string won't match: metachars break the run).
      check path, text, "hardcoded-private-key", :flag, /-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----/,
        "embeds a private key"
      # AKIAIOSFODNN7EXAMPLE is AWS's documented example key — it appears in
      # legitimate fixtures and docs everywhere and can never be a live leak.
      check path, text, "hardcoded-token", :flag, /\b(?:ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82}|(?!AKIAIOSFODNN7EXAMPLE)AKIA[0-9A-Z]{16})\b/,
        "embeds a credential token"
      # No innocent program executes decoded bytes.
      check path, text, "python-decode-exec", :flag,
        /\bexec\s*\(\s*(?:bytes\.fromhex|base64\.b(?:64)?decode|zlib\.decompress|codecs\.decode|marshal\.loads)/,
        "executes decoded bytes"
      check path, text, "shell-history-tamper", :flag, /HISTFILE=|history\s+-c\b|shred\b.*bash_history/,
        "tampers with shell history"
      # Only the plugin's OWN storage (~/.config/omarchy/plugins/...) is a
      # legitimate write target; anything else in $HOME — dotfile or not — and
      # any system path needs a human look.
      # cp/mv/install are also ordinary English words ("install detection
      # (needs login shell for ~/go/bin)") — [^\n()]* keeps the verb→path span
      # free of parentheses, which command lines essentially never contain but
      # prose almost always does.
      check path, text, "home-write", :flag,
        %r{(?:>>?|\btee\s+(?:-a\s+)?)\s*["']?(?:\$\{?HOME\}?|~)/(?!\.config/omarchy/plugins/)\S|\b(?:cp|mv|install)\b[^\n()]*\s["']?(?:\$\{?HOME\}?|~)/(?!\.config/omarchy/plugins/)\S},
        "writes into the home directory outside the plugin's own storage"
      check path, text, "system-write", :flag,
        %r{(?:>>?|\btee\s+(?:-a\s+)?)\s*["']?/(?:etc|usr|var|boot|opt|srv)/|\b(?:cp|mv|install)\b[^\n()]*\s["']?/(?:etc|usr|var|boot|opt|srv)/},
        "writes to system paths"
      check path, text, "embedded-shebang", :flag, /\n#!\s*\/(bin|usr)\//, "script payload embedded past the file header" if !entropy
      check_entropy(path, text) if entropy
    end

    # Long high-entropy blobs are the signature of obfuscated payloads.
    def check_entropy(path, text)
      record_check("obfuscation-entropy", path)
      # Embedded media data-URIs (icons inside SVGs, design mocks in HTML)
      # are the standard idiom for high-entropy base64 — strip them before
      # hunting for packed payloads, which don't announce their MIME type.
      stripped = text.gsub(%r{data:(?:image|font|audio|video)/[a-z0-9.+-]+;base64,[A-Za-z0-9+/=]+}i, "")
      stripped.scan(/[A-Za-z0-9+\/=_-]{400,}/).each do |blob|
        next if entropy(blob) < 4.5
        findings << Finding.new("obfuscation-entropy", :flag, path,
          "high-entropy blob of #{blob.length} chars (possible packed payload)")
        break
      end
    end

    def scan_metadata
      return unless @plugin&.persisted?
      record_check("dormant-plugin-update", "manifest.json")
      last = @plugin.versions.published.order(published_at: :desc).first
      if last&.published_at && last.published_at < 6.months.ago
        findings << Finding.new("dormant-plugin-update", :flag, "manifest.json",
          "first update after #{((Time.current - last.published_at) / 1.month).round} months dormant")
      end
    end

    # Regex metachar sequences that essentially never occur in real command
    # lines but define detection-signature literals (a security plugin's own
    # rule set). The hint SORTS the admin queue — it never suppresses: the
    # surrounding text is author-controlled, so auto-downgrading on it would
    # be a free evasion primitive.
    PATTERN_LITERAL_CONTEXT = /\\[sbdwSBDW]|\(\?:|\[\^|re\.compile\(|new\s+RegExp\(/

    def check(path, text, rule, severity, pattern, detail)
      record_check(rule, path)
      return unless (match = text.match(pattern))
      context = "#{match.pre_match.last(80)}#{match[0]}#{match.post_match.first(80)}"
      hint = context.match?(PATTERN_LITERAL_CONTEXT) ? " [match sits inside an apparent pattern literal — likely a detection signature, verify by eye]" : ""
      findings << Finding.new(rule, severity, path, "#{detail}: #{match[0].to_s.strip.first(80)}#{hint}")
    end

    def record_check(rule, path)
      (@checked_rules[rule] ||= Set.new) << path
    end

    def entropy(string)
      freq = string.each_char.tally
      len = string.length.to_f
      -freq.values.sum { |count| p = count / len; p * Math.log2(p) }
    end
  end
end
