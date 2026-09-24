# Shared naming rules for publishers and plugins: format, reserved words, and
# the normalization used for typosquat checks (RubyGems-style — separators
# stripped, common confusables folded).
module NameRules
  NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/
  MAX_LENGTH = 64

  # Reserved for first-party use and for registry routes/infrastructure.
  RESERVED = %w[
    omarchy omacom omacon admin api dl index plugins plugin publishers publisher
    users user settings tokens token session sessions passwords search about
    governance security audit revocations assets rails help docs new edit
    my snap snaps voice dotfiles devices s og
  ].freeze

  module_function

  CONFUSABLES = { "0" => "o", "1" => "l", "3" => "e", "5" => "s", "7" => "t", "rn" => "m", "vv" => "w" }.freeze

  # Fold a name to the form used for uniqueness-against-lookalikes checks.
  def normalize(name)
    folded = name.to_s.downcase.gsub(/[._-]/, "")
    CONFUSABLES.each { |from, to| folded = folded.gsub(from, to) }
    folded
  end

  # Checked on BOTH the raw and the confusable-normalized form — "0marchy" and
  # "omarch-y" normalize onto reserved ground and must not squat it.
  def reserved?(name)
    [ name.to_s.downcase, normalize(name) ].any? do |candidate|
      RESERVED.include?(candidate) || candidate.start_with?("omarchy") ||
        RESERVED.any? { |word| normalize(word) == candidate }
    end
  end
end
