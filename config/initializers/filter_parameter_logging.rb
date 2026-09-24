# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Registry bearer secrets: device-flow codes, sign-in/TOTP codes, passkey assertions
  :device_code, :code, :credential,
  # My Omarchy: the minted voice key
  :api_key, :minted_voice_key
]
