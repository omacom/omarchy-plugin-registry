require "vips"

module Registry
  # Server-rendered Open Graph cards (1200×630 PNG), composed with vips in the
  # site's own idiom: ink ground, paper type, one pink, hairline rules, the
  # Omacom mark. A plugin card carries the preview image when one exists; the
  # site card backs the home page and any page without something better.
  #
  # Everything is deterministic from database state — the controller caches on
  # a key derived from the same inputs.
  class OgCard
    WIDTH = 1200
    HEIGHT = 630
    MARGIN = 64

    INK = [ 13, 8, 38 ].freeze
    PAPER = [ 248, 245, 242 ].freeze
    PINK = [ 255, 138, 255 ].freeze
    MAGENTA = [ 237, 76, 200 ].freeze

    FONTS = {
      regular: [ "JetBrains Mono", "JetBrainsMono-Regular.ttf" ],
      bold: [ "JetBrains Mono Bold", "JetBrainsMono-Bold.ttf" ],
      extrabold: [ "JetBrains Mono ExtraBold", "JetBrainsMono-ExtraBold.ttf" ]
    }.freeze

    def self.plugin(plugin) = new.render_plugin(plugin)
    def self.site(stats) = new.render_site(stats)

    def render_plugin(plugin)
      preview = preview_panel(plugin)
      column = preview ? 560 : WIDTH - MARGIN * 2

      canvas = base_canvas
      canvas = header(canvas)
      eyebrow = plugin.category ? Taxonomy.label(plugin.category).upcase : Array(plugin.kinds).first.to_s.upcase
      canvas = stamp(canvas, text(eyebrow.presence || "PLUGIN", :bold, 20), MAGENTA, MARGIN, 196)
      canvas = title(canvas, publisher: "#{plugin.publisher.name}/", name: plugin.name, width: column)
      if plugin.summary.present?
        # Three lines max beside a preview panel, or the stats row below gets
        # overrun — the wide layout has room for a fourth.
        canvas = stamp(canvas, text(truncate(plugin.summary, preview ? 100 : 150), :regular, 25, width: column, spacing: 10), PAPER, MARGIN, 350, opacity: 0.72)
      end
      canvas = stamp(canvas, text(stats_line(plugin), :bold, 23), PINK, MARGIN, 494)
      canvas = footer(canvas)
      canvas = canvas.composite2(preview, :over, x: WIDTH - MARGIN - preview.width, y: 160) if preview
      png(canvas)
    end

    def render_site(stats)
      canvas = base_canvas
      canvas = header(canvas)
      canvas = stamp(canvas, text("PLUGINS.OMARCHY.ORG", :bold, 20), MAGENTA, MARGIN, 196)
      canvas = stamp(canvas, text("Make Omarchy yours.\nPlugins and themes.", :extrabold, 54, spacing: 14), PAPER, MARGIN, 240)
      line = "#{stats[:plugins]} packages · #{stats[:publishers]} publishers · #{ActiveSupport::NumberHelper.number_to_human(stats[:downloads], format: '%n%u', precision: 3, significant: true, units: { thousand: 'k', million: 'M' })} downloads"
      canvas = stamp(canvas, text(line, :bold, 23), PINK, MARGIN, 460)
      canvas = footer(canvas)
      png(canvas)
    end

    private

    def base_canvas
      canvas = Vips::Image.black(WIDTH, HEIGHT).add(INK).cast("uchar").copy(interpretation: :srgb)
      # The hairline inner rule, same idiom as the site's bordered surfaces
      canvas = canvas.mutate do |img|
        border = INK.zip(PAPER).map { |i, p| (i * 0.72 + p * 0.28).round }
        img.draw_rect!(border, 28, 28, WIDTH - 56, HEIGHT - 56)
        img.draw_rect!(INK, 29, 29, WIDTH - 58, HEIGHT - 58)
      end
      canvas
    end

    def header(canvas)
      canvas = canvas.composite2(logo(56), :over, x: MARGIN, y: 56)
      canvas = stamp(canvas, text("Omarchy", :bold, 30), PAPER, MARGIN + 156, 68)
      stamp(canvas, text("Hub", :bold, 30), PINK, MARGIN + 156 + 152, 68)
    end

    def footer(canvas)
      canvas = stamp(canvas, text("plugins.omarchy.org", :bold, 22), PINK, MARGIN, HEIGHT - 86)
      right = text("An Omacom project", :regular, 22)
      stamp(canvas, right, PAPER, WIDTH - MARGIN - right.width, HEIGHT - 86, opacity: 0.6)
    end

    # publisher/ muted, name bright — the directory card treatment at poster
    # size. Autofit (via height) keeps long names inside the column.
    def title(canvas, publisher:, name:, width:)
      full = "#{publisher}#{name}"
      # No dpi here: with a height given, vips autofits by searching dpi — a
      # fixed dpi would pin the search and render at Pango's tiny default.
      mask = Vips::Image.text(full, font: font_name(:extrabold), fontfile: font_file(:extrabold),
        width: width, height: 76)
      # Two stamps from one autofit pass would need per-glyph geometry; a
      # single bright stamp keeps it simple and reads fine at card size.
      stamp(canvas, mask, PAPER, MARGIN, 236)
    end

    def stats_line(plugin)
      parts = []
      parts << "v#{plugin.latest_version}" if plugin.latest_version
      parts << "#{ActiveSupport::NumberHelper.number_to_human(plugin.downloads_count, format: '%n%u', precision: 3, significant: true, units: { thousand: 'k', million: 'M' })} downloads"
      parts << "★ #{plugin.repo_stars}" if plugin.repo_stars.to_i.positive?
      parts << "◆ #{plugin.average_rating}/5" if plugin.average_rating
      parts.join("  ·  ")
    end

    def preview_panel(plugin)
      return nil unless plugin.preview? && plugin.preview_detail.attached?
      bytes = plugin.preview_detail.download
      # 330px height cap keeps even square-ish previews clear of the stats row
      image = Vips::Image.thumbnail_buffer(bytes, 512, height: 330, size: :down)
      image = image.flatten(background: INK) if image.has_alpha?
      # Paper hairline frame
      framed = image.embed(1, 1, image.width + 2, image.height + 2, extend: :background, background: PAPER)
      framed.copy(interpretation: :srgb)
    rescue Vips::Error
      nil
    end

    def logo(height)
      svg = <<~SVG
        <svg viewBox="0 0 1103 453" xmlns="http://www.w3.org/2000/svg" fill="#ff8aff">
          <defs>
            <mask id="omk-c"><rect x="-500" y="-500" width="2500" height="1500" fill="white"/><rect x="448.6" y="105.2" width="223.7" height="242.7" fill="black"/></mask>
            <mask id="omk-r"><rect x="-500" y="-500" width="2500" height="1500" fill="white"/><circle cx="362" cy="226.5" r="132" fill="black"/><polygon points="741,94.48 873.02,226.5 741,358.52 608.98,226.5" fill="black"/></mask>
            <mask id="omk-d"><rect x="-500" y="-500" width="2500" height="1500" fill="white"/><rect x="448.6" y="105.2" width="223.7" height="242.7" fill="black"/></mask>
          </defs>
          <circle cx="362" cy="226.5" r="132" mask="url(#omk-c)"/>
          <rect x="448.6" y="105.2" width="223.7" height="242.7" mask="url(#omk-r)"/>
          <polygon points="741,94.48 873.02,226.5 741,358.52 608.98,226.5" mask="url(#omk-d)"/>
        </svg>
      SVG
      # Rails blocks untrusted vips loaders globally (good — the preview
      # pipeline only ever decodes raster formats). This SVG is a hardcoded
      # constant, never user input, so svgload is safe to open for it.
      Vips.block("VipsForeignLoadSvg", false)
      scale = height / 453.0
      Vips::Image.svgload_buffer(svg, scale: scale)
    end

    def text(string, face, size, width: nil, spacing: nil)
      options = { font: "#{font_name(face)} #{size}", fontfile: font_file(face), dpi: 72 }
      options[:width] = width if width
      options[:spacing] = spacing if spacing
      Vips::Image.text(string.to_s, **options)
    end

    def font_name(face) = FONTS.fetch(face).first
    def font_file(face) = Rails.root.join("vendor/fonts", FONTS.fetch(face).last).to_s

    # Colorize a text mask and composite it at x, y.
    def stamp(canvas, mask, color, x, y, opacity: 1.0)
      mask = mask.extract_band(0) if mask.bands > 1
      alpha = opacity < 1.0 ? mask.linear([ opacity ], [ 0 ]).cast("uchar") : mask
      overlay = mask.new_from_image(color).bandjoin(alpha).cast("uchar").copy(interpretation: :srgb)
      canvas.composite2(overlay, :over, x: x, y: y)
    end

    def truncate(string, length)
      string.length > length ? "#{string[0, length - 1].rstrip}…" : string
    end

    def png(canvas)
      canvas.pngsave_buffer(compression: 8, palette: false)
    end
  end
end
