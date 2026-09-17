# Trusted fixture adapter: exercises orchestration and coverage, without a provider.
require "json"
require_relative "../../../lib/registry/ai_reviewer"
result = Registry::AiReviewer.new(JSON.parse(STDIN.read)) { '{"verdict":"pass","reasons":[]}' }.review
puts JSON.generate(result.merge("model" => "fixture-model"))
