require "test_helper"

# `omarchy my login`: the same RFC 8628 flow as publishing, with purpose=account.
class My::DeviceFlowTest < ActionDispatch::IntegrationTest
  setup { @user = create_my_user }

  test "account flow: code -> connect -> account token that reaches the My API but not publishing" do
    post "/api/v1/device/code", params: { purpose: "account", device: "framework" }
    assert_response :created
    assert_equal "account", response.parsed_body["purpose"]
    assert_equal "http://my.test/device", response.parsed_body["verification_uri"]
    device_code = response.parsed_body["device_code"]
    user_code = response.parsed_body["user_code"]

    sign_in_as @user
    get device_path(code: user_code)
    assert_response :success
    assert_match "Connect this machine?", response.body
    assert_match "framework", response.body
    assert_no_match "publish token", response.body

    # Whatever the form posts, an account approval never carries a publish scope
    post approve_device_path, params: { code: user_code, publisher_name: "me", plugin_name: "weather" }
    assert_redirected_to my_devices_path

    post "/api/v1/device/token", params: { device_code: device_code }
    assert_response :success
    token = response.parsed_body["token"]
    assert token.start_with?("oma_")
    assert_equal "account", response.parsed_body["purpose"]
    assert_match(/framework/, response.parsed_body["scope"])

    get "/api/v1/my/whoami", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :success
    assert_equal "me", response.parsed_body.dig("user", "handle")
    assert_equal "framework", response.parsed_body.dig("device", "name")

    post "/api/v1/plugins/me/weather/versions", params: TarballBuilder.build,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/gzip" }
    assert_response :unauthorized
  end

  test "publish flow is unchanged and its token cannot reach the My API" do
    post "/api/v1/device/code"
    assert_equal "publish", response.parsed_body["purpose"]
    assert_equal "http://registry.test/device", response.parsed_body["verification_uri"]
    device_code = response.parsed_body["device_code"]

    sign_in_as @user
    post approve_device_path, params: { code: response.parsed_body["user_code"] }
    assert_redirected_to dashboard_path

    post "/api/v1/device/token", params: { device_code: device_code }
    token = response.parsed_body["token"]
    assert token.start_with?("omp_")
    get "/api/v1/my/whoami", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :unauthorized
  end

  test "an unverified session cannot connect a device" do
    post "/api/v1/device/code", params: { purpose: "account" }
    sign_in_as @user, second_factor_verified: false
    post approve_device_path, params: { code: response.parsed_body["user_code"] }
    assert_redirected_to step_up_path
  end

  test "logout revokes the token" do
    token = account_token_for(@user)
    delete "/api/v1/my/device", headers: bearer(token)
    assert_response :no_content
    get "/api/v1/my/whoami", headers: bearer(token)
    assert_response :unauthorized
  end

  test "suspension locks machines out immediately" do
    token = account_token_for(@user)
    @user.update!(suspended_at: Time.current)
    get "/api/v1/my/whoami", headers: bearer(token)
    assert_response :forbidden
  end
end
