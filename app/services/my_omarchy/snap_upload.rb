require "vips"

module MyOmarchy
  # Ingests one shared screenshot: validates the bytes are the image they
  # claim to be (magic bytes AND the decoder agree), bounds the pixel count,
  # enforces the per-account storage quota, stores the original, and renders
  # a WebP preview for the share page and its link card.
  class SnapUpload
    class Rejected < StandardError
      attr_reader :status
      def initialize(message, status: :unprocessable_entity)
        super(message)
        @status = status
      end
    end

    # content type => [magic-byte check, expected vips loader prefix]
    FORMATS = {
      "image/png" => [ ->(b) { b.start_with?("\x89PNG\r\n\x1a\n".b) }, "pngload" ],
      "image/jpeg" => [ ->(b) { b.start_with?("\xFF\xD8\xFF".b) }, "jpegload" ],
      "image/webp" => [ ->(b) { b.byteslice(0, 4) == "RIFF" && b.byteslice(8, 4) == "WEBP" }, "webpload" ]
    }.freeze
    PREVIEW_BOX = [ 1600, 1200 ].freeze

    def initialize(user:, bytes:, content_type:, title: nil, ttl: nil, token: nil, device_name: nil)
      @user = user
      @bytes = bytes
      @content_type = content_type.to_s.split(";").first.to_s.strip.downcase
      # Header values arrive binary-encoded from Rack; make them honest UTF-8
      @title = title.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip.first(Snap::MAX_TITLE_LENGTH).presence
      @ttl = ttl
      @token = token
      @device_name = ApiToken.sanitize_device_name(device_name)
    end

    def call
      raise Rejected.new("image is empty") if @bytes.bytesize.zero?
      if @bytes.bytesize > Snap::MAX_IMAGE_BYTES
        raise Rejected.new("image exceeds #{Snap::MAX_IMAGE_BYTES / 1.megabyte}MB", status: :content_too_large)
      end
      expires_at = expiry_for(@ttl)
      width, height = validate_image!
      enforce_quota!

      snap = nil
      ApplicationRecord.transaction do
        snap = @user.snaps.create!(api_token: @token, device_name: @device_name, title: @title,
          content_type: @content_type, width: width, height: height, byte_size: @bytes.bytesize,
          expires_at: expires_at)
        snap.image.attach(io: StringIO.new(@bytes), filename: snap.filename, content_type: @content_type)
        snap.preview.attach(io: StringIO.new(preview_bytes), filename: "preview-#{snap.token}.webp",
          content_type: "image/webp")
      end
      snap
    rescue Vips::Error => e
      raise Rejected.new("could not process the image: #{e.message.to_s.lines.first.to_s.strip}")
    end

    private

    def expiry_for(ttl)
      key = ttl.presence&.to_s || "never"
      raise Rejected.new("ttl must be one of #{Snap::TTL_OPTIONS.keys.join(', ')}") unless Snap::TTL_OPTIONS.key?(key)
      Snap::TTL_OPTIONS[key]&.from_now
    end

    # Header-only checks, then dimensions: pixels are only decoded for the
    # preview, and only after the count is known to be bounded.
    def validate_image!
      magic, loader = FORMATS.fetch(@content_type) { raise Rejected.new("unsupported image type: #{@content_type.presence || 'none'}") }
      raise Rejected.new("bytes do not match the declared #{@content_type}") unless magic.call(@bytes.b)
      header = Vips::Image.new_from_buffer(@bytes, "")
      unless header.get("vips-loader").to_s.start_with?(loader)
        raise Rejected.new("image decoded as a different format than declared")
      end
      raise Rejected.new("animated images are not supported") if header.get_typeof("n-pages") != 0 && header.get("n-pages").to_i > 1
      raise Rejected.new("image exceeds #{Snap::MAX_PIXELS / 1_000_000} megapixels") if header.width * header.height > Snap::MAX_PIXELS
      [ header.width, header.height ]
    rescue Vips::Error
      raise Rejected.new("image is not decodable")
    end

    def enforce_quota!
      retained = @user.snaps.live.sum(:byte_size)
      if retained + @bytes.bytesize > Snap.max_retained_bytes_per_user
        raise Rejected.new("snap storage is full — delete some snaps first", status: :forbidden)
      end
    end

    def preview_bytes
      Vips::Image.thumbnail_buffer(@bytes, PREVIEW_BOX[0], height: PREVIEW_BOX[1], size: :down)
        .webpsave_buffer(Q: 82, effort: 4)
    end
  end
end
