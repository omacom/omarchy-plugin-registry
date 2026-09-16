module Registry
  # Rails only supplies bounded display data. Native drawing, text rendering,
  # and decoding happen in the same isolated, networkless tier as previews.
  class OgCard
    class Unavailable < StandardError; end

    def self.plugin(plugin)
      parts = []
      parts << "v#{plugin.latest_version}" if plugin.latest_version
      parts << "#{human_count(plugin.downloads_count)} downloads"
      parts << "★ #{plugin.repo_stars}" if plugin.repo_stars.to_i.positive?
      parts << "◆ #{plugin.average_rating}/5" if plugin.average_rating
      eyebrow = plugin.category ? Taxonomy.label(plugin.category).upcase : Array(plugin.kinds).first.to_s.upcase
      data = { publisher: plugin.publisher.name, name: plugin.name, summary: plugin.summary.to_s.first(150),
               eyebrow: eyebrow.presence || "PLUGIN", stats_line: parts.join("  ·  ") }
      if plugin.preview? && plugin.preview_card.attached? && plugin.preview_card.byte_size <= 10.megabytes
        data[:preview] = Base64.strict_encode64(plugin.preview_card.download)
      end
      render("plugin", data)
    end

    def self.site(stats)
      render("site", { stats_line: "#{stats[:plugins]} packages · #{stats[:publishers]} publishers · #{human_count(stats[:downloads])} downloads" })
    end

    def self.human_count(count)
      ActiveSupport::NumberHelper.number_to_human(count, format: "%n%u", precision: 3, significant: true,
        units: { thousand: "k", million: "M" })
    end

    def self.render(kind, data)
      output = ProcessorSandbox.call(:og, JSON.generate({ kind:, data: }),
        timeout: 45, max_output_bytes: 4.megabytes)
      raise Unavailable, "social card processor returned invalid output" unless output.b.start_with?("\x89PNG\r\n\x1a\n".b)
      output
    rescue UntrustedProcess::Failed
      raise Unavailable, "social card processor unavailable"
    end
    private_class_method :render, :human_count
  end
end
