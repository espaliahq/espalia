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
  attribute :metadata, default: -> { {} }

  validates :system, inclusion: { in: SYSTEMS }, allow_nil: true

  # Whether this reference carries any populated information.
  #
  # @return [Boolean]
  def present?
    [ system, url, external_id ].any? { |v| v.to_s.strip.present? } ||
      (metadata.is_a?(Hash) && metadata.any?)
  end
end
