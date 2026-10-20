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

  # Systems people commonly point at, offered to MCP clients as examples. Any
  # slug is accepted, so a new feedback exchange peer needs no code change.
  KNOWN_SYSTEMS = %w[github gitlab linear jira slack notion google_doc figma chip other].freeze
  SYSTEM_FORMAT = /\A[a-z0-9]+(?:[_-][a-z0-9]+)*\z/

  # The only keys an external_reference payload may carry. Used both to
  # reject unknown keys with a clear message (rather than the opaque
  # ActiveModel::UnknownAttributeError StoreModel raises on construction)
  # and to publish the accepted shape in the MCP tool schema.
  ATTRIBUTE_NAMES = %w[system url external_id metadata].freeze

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
  # format validation below.
  normalizes :system, :url, :external_id, with: ->(v) { v.to_s.strip.presence }

  validates :system, format: { with: SYSTEM_FORMAT, message: "must be a lowercase slug, such as github or google_doc" },
                     allow_nil: true
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

  # Validates an external_reference payload (the raw Hash a caller — web
  # form or MCP client — submitted) WITHOUT raising. Returns a
  # human-readable reason it's unacceptable, or nil when it's fine (incl.
  # a blank/empty payload, which is always allowed).
  #
  # Constructing `new(payload)` directly raises ActiveModel::Unknown-
  # AttributeError on any key outside {ATTRIBUTE_NAMES} — that's how a
  # stray `title:` key surfaced to MCP clients as an opaque -32603
  # internal error. Callers route the returned reason into their own
  # validation error (a -32602 invalid-params for MCP) instead.
  #
  # @param payload [Hash, nil]
  # @return [String, nil]
  def self.validation_error_for(payload)
    return nil if payload.blank?
    return "must be an object" unless payload.respond_to?(:keys)

    unknown = payload.keys.map(&:to_s) - ATTRIBUTE_NAMES
    if unknown.any?
      return "unknown field#{'s' if unknown.size > 1} #{unknown.sort.join(', ')} " \
             "(allowed: #{ATTRIBUTE_NAMES.join(', ')})"
    end

    candidate = new(payload)
    return nil if candidate.valid?

    candidate.errors.full_messages.join(", ")
  rescue ActiveModel::UnknownAttributeError => e
    # Defensive: any unknown-key path still yields a reason, never a raise.
    e.message
  end

  # JSON Schema fragment describing the accepted payload shape, published
  # in the MCP tool schema so clients see the keys (and the systems we know)
  # instead of a bare free-form object they have to guess at.
  #
  # @return [Hash]
  def self.json_schema
    {
      type: "object",
      description: "Optional pointer to a supporting source in an external system.",
      properties: {
        system:      { type: "string", pattern: SYSTEM_FORMAT.source.sub("\\A", "^").sub("\\z", "$"),
                       examples: KNOWN_SYSTEMS,
                       description: "Originating system, as a lowercase slug." },
        url:         { type: "string", description: "An http(s) link to the source." },
        external_id: { type: "string", description: "The item's ID within that system." },
        metadata:    { type: "object", description: "Free-form additional fields." }
      },
      additionalProperties: false
    }
  end

  # Whether the item this points from was imported from a feedback exchange
  # peer: the importer is the only writer of `given_at`, which every protocol
  # record carries.
  #
  # @return [Boolean]
  def imported?
    metadata.is_a?(Hash) && (metadata["given_at"] || metadata[:given_at]).present? && system.present?
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
