require "test_helper"

# The shared server/client validation contract, as data: every corpus case in
# test/conformance/corpus/*.json runs against the registry's validator here,
# and the SAME files are the conformance suite for the Quattro-side
# omarchy-plugin-validate (see docs/client-spec.md). Divergence between the
# two validators is a corpus failure on one side or the other — not a guess.
class ManifestValidatorCorpusTest < ActiveSupport::TestCase
  CORPUS = Dir[Rails.root.join("test/conformance/corpus/*.json")].sort

  test "corpus is present" do
    assert_operator CORPUS.length, :>=, 18
  end

  CORPUS.each do |path|
    kase = JSON.parse(File.read(path))
    test "corpus: #{kase['name']}" do
      publisher = Publisher.new(name: "acme", kind: :org)
      files = kase["files"].transform_values(&:to_s)
      bytes = TarballBuilder.build(manifest: kase["manifest"], files: files)
      begin
        tarball = Registry::TarballInspector.inspect_bytes(bytes)
      rescue Registry::TarballInspector::InvalidTarball => e
        assert_equal "invalid", kase["expect"], e.message
        assert_includes e.message, kase["reason"] if kase["reason"]
        next
      end
      validator = Registry::ManifestValidator.new(
        manifest: tarball.manifest, publisher: publisher, plugin_name: "weather", tarball: tarball)

      if kase["expect"] == "valid"
        assert validator.valid?, "expected valid, got: #{validator.errors.join('; ')}"
      else
        assert_not validator.valid?, "expected invalid"
        if kase["reason"]
          assert validator.errors.join("; ").include?(kase["reason"]),
            "expected error matching #{kase['reason'].inspect}, got: #{validator.errors.join('; ')}"
        end
      end
    end
  end
end
