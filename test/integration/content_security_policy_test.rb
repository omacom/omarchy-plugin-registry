require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "inline scripts use a fresh nonce accepted by the response policy" do
    nonces = 2.times.map do
      get root_path
      assert_response :success
      nonce = response.headers.fetch("Content-Security-Policy")[/\bnonce-([^']+)/, 1]
      assert nonce.present?
      assert_select "script:not([src])" do |scripts|
        assert scripts.any?
        scripts.each { |script| assert_equal nonce, script["nonce"] }
      end
      nonce
    end
    assert_not_equal nonces.first, nonces.last
  end
end
