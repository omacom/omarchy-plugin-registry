require "test_helper"

class AiReviewerTest < ActiveSupport::TestCase
  PASS = JSON.generate({ verdict: "pass", reasons: [] }).freeze

  def request(files = {})
    { "sha256" => "a" * 64, "files" => files, "verified_assets" => [], "incomplete_files" => [] }
  end

  test "every character of long single-line and unusually named source reaches review" do
    files = { "Widget.qml" => "ordinary text " * 2000, "notes.dat" => "more plain text", "README.md" => "hello" }
    seen = []
    result = Registry::AiReviewer.new(request(files), chunk_chars: 1000) do |json|
      seen.concat(JSON.parse(json).fetch("source_parts"))
      PASS
    end.review
    assert_equal "pass", result["verdict"]
    assert result.dig("coverage", "complete")
    files.each do |path, contents|
      parts = seen.select { |part| part["path"] == path }.sort_by { |part| part["offset"] }
      assert_equal contents, parts.map { |part| part["content"] }.join
      assert_equal contents.length, parts.last["offset"] + parts.last["content"].length
    end
  end

  test "UTF-8 splitting preserves complete content" do
    source = "café 日本語 " * 20
    seen = []
    result = Registry::AiReviewer.new(request("message.txt" => source), chunk_chars: 17) do |json|
      seen.concat(JSON.parse(json)["source_parts"].map { |part| part["content"] })
      PASS
    end.review
    assert_equal "pass", result["verdict"]
    assert_equal source, seen.join
  end

  test "context overflow flags without substituting partial-file review" do
    result = Registry::AiReviewer.new(request("file.txt" => "ordinary text")) do |_json|
      raise StandardError, "context window exceeded"
    end.review
    assert_equal "flag", result["verdict"]
    assert_not result.dig("coverage", "complete")
  end

  test "review-budget overflow is a coverage failure without model calls" do
    calls = 0
    result = Registry::AiReviewer.new(request("file.txt" => "a" * 40), chunk_chars: 10, max_chunks: 2) do |_json|
      calls += 1
      PASS
    end.review
    assert_equal "flag", result["verdict"]
    assert_not result.dig("coverage", "complete")
    assert_equal 0, calls
  end

  test "inspector-truncated source cannot pass even with a clean model" do
    result = Registry::AiReviewer.new(request("file.txt" => "excerpt").merge("incomplete_files" => [ "file.txt" ])) { PASS }.review
    assert_equal "flag", result["verdict"]
    assert_not result.dig("coverage", "complete")
  end

  test "only server-verified assets may be omitted and coverage binds the archive" do
    envelope = request("preview.png" => "", "README.md" => "hello")
      .merge("verified_assets" => [ "preview.png" ], "incomplete_files" => [ "preview.png" ])
    result = Registry::AiReviewer.new(envelope) { PASS }.review
    assert_equal "pass", result["verdict"]
    assert_equal envelope["sha256"], result.dig("coverage", "archive_sha256")
    assert result.dig("coverage", "complete")
  end

  test "model output must be a strict verdict document" do
    [ "text before #{PASS}", '{"verdict":"pass","reasons":["uncertain"]}',
      '{"verdict":"flag","reasons":[]}', '{"verdict":"pass"}', "[]" ].each do |output|
      result = Registry::AiReviewer.new(request("file.txt" => "hello")) { output }.review
      assert_equal "flag", result["verdict"]
      assert_not result.dig("coverage", "complete")
    end
  end

  test "deadline failure cannot record complete coverage" do
    time = 0
    result = Registry::AiReviewer.new(request("file.txt" => "hello"), deadline_seconds: 1, clock: -> { time }) do |_json|
      time = 2
      PASS
    end.review
    assert_equal "flag", result["verdict"]
    assert_not result.dig("coverage", "complete")
  end

  test "a flag in any part keeps the entire review flagged" do
    calls = 0
    result = Registry::AiReviewer.new(request("file.txt" => "ordinary source"), chunk_chars: 10) do |_json|
      calls += 1
      calls == 1 ? JSON.generate({ verdict: "flag", reasons: [ "needs human judgment" ] }) : PASS
    end.review
    assert_equal "flag", result["verdict"]
    assert result.dig("coverage", "complete")
    assert_includes result["reasons"], "needs human judgment"
  end
end
