# One immutable snapshot of a machine's Omarchy configuration, pushed by
# `omarchy my sync push`. The archive is an Active Storage blob — a plain
# tar.gz the server has walked and listed, or an age-encrypted one the server
# can only store (the client-declared manifest is the only listing then).
# Bundles are never edited; a push makes a new one and old ones age out.
class DotfileBundle < ApplicationRecord
  MAX_ARCHIVE_BYTES = 25.megabytes
  MAX_UNPACKED_BYTES = 100.megabytes
  MAX_ENTRIES = 5_000
  # Snapshots kept per account; a push past this purges the oldest.
  KEEP_PER_USER = 10

  # Paths a dotfile bundle must never carry. The client excludes them; the
  # server refuses them anyway — my.omarchy.org is a sync target for
  # configuration, not a vault for private keys.
  FORBIDDEN_PATHS = [
    %r{\A\.ssh/},
    %r{\A\.gnupg/},
    %r{\A\.aws/},
    %r{\A\.netrc\z},
    %r{\A\.config/gh/hosts\.yml\z},
    %r{\A\.password-store/},
    %r{\A\.local/share/keyrings/},
    %r{\A\.config/(google-chrome|chromium|BraveSoftware)/},
    %r{\A\.config/omarchy/agents/.*\.json\z},
    %r{\.(pem|key|p12|pfx|kdbx)\z},
    %r{(\A|/)id_(rsa|ed25519|ecdsa|dsa)(\.pub)?\z}
  ].freeze

  belongs_to :user
  belongs_to :api_token, optional: true
  has_one_attached :archive

  enum :encryption, { plain: 0, age: 1 }, prefix: true

  validates :sha256, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :size_bytes, numericality: { greater_than: 0, less_than_or_equal_to: MAX_ARCHIVE_BYTES }
  validates :file_count, numericality: { greater_than_or_equal_to: 0 }
  validates :device_name, format: { with: ApiToken::DEVICE_NAME_FORMAT }, allow_nil: true
  validate :manifest_is_an_object

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.forbidden_path?(path) = FORBIDDEN_PATHS.any? { |pattern| path.match?(pattern) }

  def paths = Array(manifest["paths"])

  def omarchy_version = manifest["omarchy_version"].presence

  private

  def manifest_is_an_object
    errors.add(:manifest, "must be a JSON object") unless manifest.is_a?(Hash)
  end
end
