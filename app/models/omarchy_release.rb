class OmarchyRelease < ApplicationRecord
  has_many :compatibility_assessments, dependent: :restrict_with_error
  attr_readonly :version, :build, :channel, :apis

  validates :version, uniqueness: { scope: :build }
  validates :channel, inclusion: { in: %w[stable candidate development] }
  validates :build, format: { with: /\A[a-zA-Z0-9._-]{0,80}\z/ }
  validate :valid_contract

  def label = [ version, build.presence ].compact.join(" / ")
  def entry = { "version" => version, "build" => build, "channel" => channel, "apis" => apis }

  private

  def valid_contract
    errors.add(:version, "must be strict semver without build metadata") unless Semver.valid?(version) && !version.include?("+")
    errors.add(:build, "is required for candidate and development releases") if channel != "stable" && build.blank?
    errors.add(:channel, "must be candidate or development for a prerelease") if version.to_s.include?("-") && channel == "stable"
    unless apis.is_a?(Hash) && apis.keys.sort == %w[plugin theme] && apis.values.all? { |v| v.is_a?(Array) && v.any? && v.size <= 20 && v.uniq == v && v.all? { |n| n.is_a?(Integer) && (1..10000).cover?(n) } }
      errors.add(:apis, "must list supported integer plugin and theme API versions")
    end
  end
end
