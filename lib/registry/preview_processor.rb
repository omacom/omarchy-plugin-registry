require "vips"

module Registry
  # Turns the optional root preview shipped inside a plugin tarball into the
  # two WebP renditions the site serves: a card thumbnail for the directory
  # grid and a larger detail image for the plugin page. Animated GIFs stay
  # animated on the detail page (re-encoded as animated WebP) and freeze to
  # their first frame on cards.
  #
  # validate! runs synchronously at publish time so a broken image fails the
  # upload with a clear message instead of surfacing as a half-broken page;
  # process runs later, at release, on bytes validate! already accepted.
  class PreviewProcessor
    class InvalidPreview < StandardError; end

    # Same spirit as the tarball caps: generous for real screenshots, hostile
    # to decompression bombs. Animated previews are screen recordings — small
    # frames, bounded frame count.
    MAX_STATIC_PIXELS = 40_000_000
    MAX_FRAME_PIXELS = 4_000_000
    MAX_FRAMES = 500
    MAX_TOTAL_PIXELS = 80_000_000

    CARD_BOX = [ 720, 720 ].freeze
    DETAIL_BOX = [ 1600, 1200 ].freeze
    ANIMATED_DETAIL_BOX = [ 960, 720 ].freeze

    # extension => [magic-byte check, expected vips loader prefix]
    FORMATS = {
      ".png" => [ ->(b) { b.start_with?("\x89PNG\r\n\x1a\n".b) }, "pngload" ],
      ".jpg" => [ ->(b) { b.start_with?("\xFF\xD8\xFF".b) }, "jpegload" ],
      ".jpeg" => [ ->(b) { b.start_with?("\xFF\xD8\xFF".b) }, "jpegload" ],
      ".webp" => [ ->(b) { b.byteslice(0, 4) == "RIFF" && b.byteslice(8, 4) == "WEBP" }, "webpload" ],
      ".gif" => [ ->(b) { b.start_with?("GIF87a") || b.start_with?("GIF89a") }, "gifload" ]
    }.freeze

    def self.validate!(bytes, name:)
      new(bytes, name:).validate!
    end

    def self.process(bytes, name:)
      new(bytes, name:).process
    end

    def initialize(bytes, name:)
      @bytes = bytes
      @name = name
    end

    # Even header parsing is native code: invoke only inside the processor,
    # never in the Rails request or review worker process.
    def validate!
      magic, loader = FORMATS.fetch(File.extname(@name).downcase) do
        raise InvalidPreview, "unsupported preview format: #{@name}"
      end
      raise InvalidPreview, "#{@name} does not contain #{File.extname(@name).delete_prefix('.').upcase} data" unless magic.call(@bytes.b)

      header = load_header
      unless header.get("vips-loader").to_s.start_with?(loader)
        raise InvalidPreview, "#{@name} decoded as a different format than its extension claims"
      end

      frames = frame_count(header)
      frame_height = meta_int(header, "page-height", default: header.height)
      if header.width * frame_height * frames > MAX_TOTAL_PIXELS
        raise InvalidPreview, "preview exceeds aggregate pixel budget"
      end
      if frames > 1
        raise InvalidPreview, "animated preview exceeds #{MAX_FRAMES} frames" if frames > MAX_FRAMES
        if header.width * frame_height > MAX_FRAME_PIXELS
          raise InvalidPreview, "animated preview frames exceed #{MAX_FRAME_PIXELS / 1_000_000} megapixels — resize the recording"
        end
      elsif header.width * frame_height > MAX_STATIC_PIXELS
        raise InvalidPreview, "preview exceeds #{MAX_STATIC_PIXELS / 1_000_000} megapixels"
      end
      true
    end

    def process
      validate!
      header = load_header
      animated = frame_count(header) > 1
      source_height = meta_int(header, "page-height", default: header.height)

      card = encode(thumbnail(*CARD_BOX), quality: 78)
      detail = animated ? encode(thumbnail(*ANIMATED_DETAIL_BOX, animated: true), quality: 70) : encode(thumbnail(*DETAIL_BOX), quality: 82)

      {
        card: card,
        detail: detail,
        meta: {
          "source" => @name,
          "animated" => animated,
          "source_width" => header.width,
          "source_height" => source_height,
          "card" => dimensions(card),
          "detail" => dimensions(detail, animated: animated)
        }
      }
    rescue Vips::Error => e
      raise InvalidPreview, "could not process #{@name}: #{e.message.to_s.lines.first.to_s.strip}"
    end

    private

    def load_header
      Vips::Image.new_from_buffer(@bytes, "")
    rescue Vips::Error
      raise InvalidPreview, "#{@name} is not a decodable image"
    end

    def frame_count(image)
      meta_int(image, "n-pages", default: 1)
    end

    # Header fields are format-dependent — absent means "single frame", never
    # an error.
    def meta_int(image, field, default:)
      image.get_typeof(field).zero? ? default : image.get(field)
    end

    # thumbnail_buffer streams the decode and never upscales; n=-1 keeps every
    # frame of an animation, the default keeps only the first.
    def thumbnail(width, height, animated: false)
      Vips::Image.thumbnail_buffer(@bytes, width,
        height: height, size: :down, **(animated ? { option_string: "n=-1" } : {}))
    end

    def encode(image, quality:)
      image.webpsave_buffer(Q: quality, effort: 4)
    end

    def dimensions(webp_bytes, animated: false)
      rendered = Vips::Image.new_from_buffer(webp_bytes, "")
      { "width" => rendered.width, "height" => meta_int(rendered, "page-height", default: rendered.height) }
    end
  end
end
