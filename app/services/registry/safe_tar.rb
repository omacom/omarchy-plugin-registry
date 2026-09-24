require "rubygems/package"
require "zlib"

module Registry
  # The one tar reader every upload goes through — plugin tarballs and My
  # Omarchy dotfile bundles alike. Never extracts to disk. Refuses everything
  # an extractor could be tricked by: symlinks, hardlinks, devices, absolute
  # or escaping paths, PAX records that rewrite extraction, duplicate paths,
  # file/directory conflicts, and bytes hidden after the archive proper.
  #
  # Yields [path, content] for every regular file, in archive order, with the
  # path already canonical ("./a//b" -> "a/b").
  module SafeTar
    class Invalid < StandardError; end

    # Only NUL padding may follow the tar terminator, and not much of it —
    # anything else is a smuggling attempt (and an unbounded drain would be a
    # decompression bomb of its own).
    MAX_TRAILING_PADDING = 64 * 1024

    module_function

    def each_file(bytes, max_entries:, max_unpacked_bytes:)
      files = Set.new
      directories = Set.new
      unpacked = 0
      entry_count = 0

      each_tar_entry(bytes) do |entry|
        # Count EVERY entry (directories included) so an archive can't smuggle
        # unbounded headers past a files-only limit.
        entry_count += 1
        raise Invalid, "too many entries" if entry_count > max_entries

        path = clean_path(entry.full_name)
        # Every entry's declared size counts against the cap BEFORE any type
        # skip — a "directory" with a payload still costs decompression work.
        unpacked += entry.header.size
        raise Invalid, "unpacked size exceeds limit" if unpacked > max_unpacked_bytes

        case
        when entry.directory?
          # Tracked so an explicit directory entry can't collide with a file
          directories << path
          next
        when entry.header.typeflag == "x"
          # Per-file PAX headers can rewrite what an extractor produces
          # (path, linkpath, sparse maps, …) — the served bytes keep them, so
          # none are allowed. Uploads never legitimately need them.
          raise Invalid, "per-file PAX extended headers are not allowed"
        when entry.header.typeflag == "g"
          # Global PAX header: git archive always emits one comment record.
          # Allowlist exactly that — every other key could affect extraction.
          pax = entry.read.to_s
          unless pax.split("\n").reject(&:empty?).all? { |record| record.match?(/\A\d+ comment=/) }
            raise Invalid, "global PAX header may only carry a comment"
          end
          next
        when entry.symlink? || entry.header.typeflag == "1"
          raise Invalid, "symlinks and hardlinks are not allowed (#{path})"
        when !entry.file?
          raise Invalid, "unsupported entry type for #{path}"
        end

        # Duplicate paths would let reviewed bytes differ from unpacked bytes
        # depending on which entry a consumer picks — never ambiguous.
        raise Invalid, "duplicate path in tarball: #{path}" if files.include?(path)
        files << path
        yield path, entry.read.to_s
      end

      # A file whose path is also a directory prefix of another entry can't be
      # extracted by any normal tool — an unextractable archive must never
      # become an immutable release.
      files.each do |candidate|
        raise Invalid, "path conflict: #{candidate} is both a file and a directory" if directories.include?(candidate)
        prefix = candidate.rpartition("/").first
        until prefix.empty?
          raise Invalid, "path conflict: #{prefix} is both a file and a directory" if files.include?(prefix)
          prefix = prefix.rpartition("/").first
        end
      end
      files
    rescue Zlib::Error, Gem::Package::TarInvalidError => e
      raise Invalid, "not a valid gzipped tarball: #{e.message}"
    end

    def each_tar_entry(bytes, &block)
      Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gz|
        Gem::Package::TarReader.new(gz) { |tar| tar.each(&block) }
        # Reviewed bytes must equal extracted bytes: a concatenated gzip could
        # hide extra tar records in a second member that gunzip would extract
        # but this reader never saw. Drain boundedly and refuse leftovers.
        drained = 0
        while (chunk = gz.read(16 * 1024))
          drained += chunk.bytesize
          if drained > MAX_TRAILING_PADDING || chunk.delete("\0").present?
            raise Invalid, "trailing data after the tar archive"
          end
        end
        raise Invalid, "trailing data after the gzip stream" if gz.unused.present?
      end
    end

    # Normalize to canonical root-relative paths — "./x", "././x", and "a//b"
    # must collapse to the same path extraction would produce, or duplicate
    # detection can be sidestepped. Escapes are refused outright.
    def clean_path(raw)
      raise Invalid, "illegal path in tarball: #{raw.inspect}" if raw.include?("\0") || raw.start_with?("/")
      # Names must be valid UTF-8 with no control characters — anything else
      # would poison fingerprint/scan JSON persistence downstream (and is a
      # smuggling vector in listings)
      utf8 = raw.dup.force_encoding(Encoding::UTF_8)
      unless utf8.valid_encoding? && !utf8.match?(/[\x00-\x1f\x7f]/)
        raise Invalid, "tarball path is not clean UTF-8: #{raw.inspect}"
      end
      segments = raw.split("/").reject { |segment| segment == "." || segment.empty? }
      raise Invalid, "illegal path in tarball: #{raw.inspect}" if segments.empty? || segments.include?("..")
      segments.join("/")
    end
  end
end
