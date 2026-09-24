require "vips"

# Real image bytes for snap tests, rendered by vips so the decoder agrees
# with the magic bytes.
module ImageFixture
  module_function

  def png(width: 640, height: 400)
    Vips::Image.black(width, height, bands: 3).add([ 30, 120, 200 ]).cast("uchar").pngsave_buffer
  end

  def jpeg(width: 640, height: 400)
    Vips::Image.black(width, height, bands: 3).add([ 200, 60, 30 ]).cast("uchar").jpegsave_buffer(Q: 80)
  end

  def webp(width: 640, height: 400)
    Vips::Image.black(width, height, bands: 3).add([ 20, 200, 90 ]).cast("uchar").webpsave_buffer(Q: 80)
  end
end
