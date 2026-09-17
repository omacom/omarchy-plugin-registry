module Registry
  # Themes are data consumed by Omarchy's own templates. The accepted grammar
  # is deliberately smaller than TOML: no escaping, interpolation, executable
  # overrides or arbitrary strings can reach generated Lua, shell or sed code.
  # Keep this contract paired with Omarchy's theme validator and shared corpus.
  class ThemeValidator
    MAX_TEXT_BYTES = 64.kilobytes
    IMAGE_PATH = %r{\A(?:backgrounds/[A-Za-z0-9][A-Za-z0-9._-]*|preview(?:[1-4]|-unlock)?|(?:lock|unlock|screensaver))\.(?:png|jpg|jpeg|webp|gif)\z}
    DOCUMENT_PATH = %r{\A(?:(?:README|LICENSE|LICENCE|COPYING|NOTICE|CHANGELOG)(?:[.-][A-Za-z0-9_-]+)*|docs/[A-Za-z0-9_./-]+\.md)\z}i
    KEY = /[a-z][a-z0-9_]*/
    COLOR = /#[0-9a-fA-F]{6}/
    GRADIENT = /(?:\#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?|rgb\([0-9a-fA-F]{6}\)|rgba\([0-9a-fA-F]{8}\))(?: +(?:\#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?|rgb\([0-9a-fA-F]{6}\)|rgba\([0-9a-fA-F]{8}\)))*(?: +-?\d{1,3}(?:\.\d+)?deg)?/
    REQUIRED_COLORS = %w[accent background foreground red green yellow blue magenta cyan].freeze

    attr_reader :errors

    def initialize(tarball)
      @errors = []
      @tarball = tarball
      validate
    end

    private

    def validate
      errors << "theme requires colors.toml" unless @tarball.include?("colors.toml")
      @tarball.files.each do |path|
        errors << "theme files must not be executable: #{path}" unless (@tarball.modes.fetch(path, 0) & 0o111).zero?
        case path
        when "manifest.json", DOCUMENT_PATH, IMAGE_PATH
          # Archive safety, generic text/malware rules and asset magic checks
          # still run in the shared inspector/scanner and review pipeline.
        when "colors.toml"
          validate_palette(path)
        when /\Ashell(?:\.[a-z][a-z0-9_-]*)?\.toml\z/
          validate_shell(path)
        when "light.mode"
          errors << "light.mode must be empty" unless text(path).strip.empty?
        when "icons.theme"
          errors << "icons.theme must name an installed icon theme" unless text(path).strip.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,79}\z/)
        when "chromium.theme"
          values = text(path).strip.split(",")
          unless values.size == 3 && values.all? { |v| v.match?(/\A\s*\d{1,3}\s*\z/) && v.to_i <= 255 }
            errors << "chromium.theme must contain three RGB integers (0–255)"
          end
        else
          errors << "unsupported theme file: #{path}; ship palette, shell appearance and images; Omarchy generates application configs"
        end
      end
    end

    def text(path)
      content = @tarball.contents.fetch(path, "").dup.force_encoding(Encoding::UTF_8)
      if @tarball.truncated.include?(path) || content.bytesize > MAX_TEXT_BYTES || !content.valid_encoding?
        errors << "#{path} must be UTF-8 text of at most 64KB"
        return ""
      end
      content
    end

    def assignments(path, sections: false)
      seen = Set.new
      section = ""
      text(path).each_line.with_index(1) do |line, number|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        if sections && (match = line.match(/\A\[([a-z][a-z0-9_-]*)\]\s*(?:#.*)?\z/))
          section = match[1]
          next
        end
        match = line.match(/\A([a-z][a-z0-9_-]*)\s*=\s*(?:"([^"\\]*)"|'([^'\\]*)'|(true|false|-?\d+(?:\.\d+)?))\s*(?:#.*)?\z/)
        unless match
          errors << "#{path}:#{number}: expected a simple literal assignment"
          next
        end
        key, double, single, scalar = match.captures
        value = double || single || scalar
        identity = [ section, key ]
        errors << "#{path}:#{number}: duplicate key #{key}" unless seen.add?(identity)
        yield key, value, scalar.present?
      end
      seen.map(&:last)
    end

    def validate_palette(path)
      keys = assignments(path) do |key, value, scalar|
        valid = key.match?(/\A#{KEY}\z/) && !scalar &&
          if %w[mode theme_type].include?(key)
            %w[light dark].include?(value)
          else
            value.match?(/\A#{GRADIENT}\z/)
          end
        errors << "#{path}: #{key} must be a hex color/gradient, or light/dark for mode" unless valid
        if REQUIRED_COLORS.include?(key) && !value.match?(/\A#{COLOR}\z/)
          errors << "#{path}: required color #{key} must be #RRGGBB"
        end
      end
      missing = REQUIRED_COLORS - keys
      errors << "colors.toml missing required colors: #{missing.join(', ')}" if missing.any?
    end

    def validate_shell(path)
      assignments(path, sections: true) do |key, value, scalar|
        unless scalar || value.match?(/\A#{GRADIENT}\z/) || value.match?(/\A[a-zA-Z0-9 _.-]{0,80}\z/)
          errors << "#{path}: #{key} must be a literal appearance value"
        end
      end
    end
  end
end
