# frozen_string_literal: true

# Pointer from an {EvidenceItem} into an external system (GitHub, Linear,
# Slack, etc.).
#
# Stored inline as a JSONB column, validated as a StoreModel value
# object. All four fields are optional — an evidence item may have no
# external reference at all (the parent column defaults to `{}`), or
# may carry a partial pointer (system + url with no external_id).
#
# @example
#   ExternalReference.new(system: "github", url: "https://github.com/org/repo/pull/42")
#
class ExternalReference
  include StoreModel::Model

  SYSTEMS = %w[github gitlab linear jira slack notion google_doc figma other].freeze

  attribute :system, :string
  attribute :url, :string
  attribute :external_id, :string
  # `metadata` is intentionally untyped — StoreModel does not register a
  # `:json` attribute type, and the parent column is JSONB so the hash
  # round-trips natively. Matches the convention used by `HrisRoleMapping`.
  attribute :metadata, default: -> { {} }

  # Normalise empty / whitespace-only strings to nil so an external
  # reference left untouched in the form (the modal's inputs always
  # submit, even when the user doesn't fill them in) round-trips as a
  # blank reference rather than persisting `""` and tripping the
  # inclusion validation below.
  normalizes :system, :url, :external_id, with: ->(v) { v.to_s.strip.presence }

  validates :system, inclusion: { in: SYSTEMS }, allow_nil: true
  validate :url_scheme_must_be_http_or_https

  # Returns the URL only if it has a safe http(s) scheme. Blocks
  # `javascript:`, `data:`, `vbscript:`, and other interactive schemes
  # that would execute on click when rendered as an <a href>.
  #
  # @return [String, nil]
  def safe_url
    return nil if url.blank?

    parsed = URI.parse(url) rescue nil
    return nil unless parsed && %w[http https].include?(parsed.scheme&.downcase)

    url
  end

  # Whether this reference carries any populated information.
  #
  # @return [Boolean]
  def present?
    [ system, url, external_id ].any? { |v| v.to_s.strip.present? } ||
      (metadata.is_a?(Hash) && metadata.any?)
  end

  # @return [Boolean]
  def blank?
    !present?
  end

  private

  def url_scheme_must_be_http_or_https
    return if url.blank?
    return if safe_url

    errors.add(:url, "must be an http or https URL")
  end
end
