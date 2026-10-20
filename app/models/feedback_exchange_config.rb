# frozen_string_literal: true

# Typed settings for the feedback exchange with a peer system, stored in
# Tenant.feedback_exchange_config JSONB.
#
# Holds nothing secret: the shared signing secrets live in the encrypted
# `feedback_exchange_credentials` column (see {Tenant#feedback_exchange_secrets}).
#
# @example
#   tenant.feedback_exchange_config.peer_name   # => "chip"
#   tenant.feedback_exchange_config.configured?(tenant) # => true
class FeedbackExchangeConfig
  include StoreModel::Model

  PROVIDERS = %w[exchange].freeze
  DEFAULT_EXPORT_KINDS = %w[peer_feedback manager_feedback observation impact].freeze
  SLUG_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  attribute :provider, :string, default: "exchange"
  attribute :peer_name, :string
  attribute :base_url, :string
  attribute :enabled, :boolean, default: false
  attribute :import_kinds, default: -> { [] }
  attribute :export_kinds, default: -> { DEFAULT_EXPORT_KINDS.dup }
  attribute :cursor, :string
  attribute :deletions_cursor, :string
  attribute :last_synced_at, :datetime
  attribute :suggestions_enabled, :boolean, default: false

  validates :provider, inclusion: { in: PROVIDERS }
  validates :peer_name, format: { with: SLUG_FORMAT, message: "must be a slug: lowercase letters, numbers and dashes" },
                        allow_blank: true
  validates :peer_name, :base_url, presence: true, if: :enabled?
  validate :base_url_is_secure
  validate :kinds_are_evidence_types

  # Whether the exchange can run: a peer is named and reachable, switched on,
  # and both secrets are stored.
  #
  # @param tenant [Tenant] the parent tenant, which holds the secrets
  # @return [Boolean]
  def configured?(tenant)
    peer_name.present? && state(secrets_complete: tenant.feedback_exchange_secrets.complete?) == :active
  end

  # The labels the settings form uses, so an error names the field the admin sees.
  ATTRIBUTE_LABELS = {
    "base_url" => "Peer address", "peer_name" => "Peer name",
    "import_kinds" => "Types to import", "export_kinds" => "Types to send"
  }.freeze

  # @return [String]
  def self.human_attribute_name(attribute, options = {})
    ATTRIBUTE_LABELS.fetch(attribute.to_s) { super }
  end

  # Where the exchange stands, from least to most set up.
  #
  # @param secrets_complete [Boolean] both signing secrets stored
  # @return [Symbol] :not_configured, :missing_secrets, :disabled or :active
  def state(secrets_complete:)
    return :not_configured if base_url.blank?
    return :missing_secrets unless secrets_complete
    return :disabled unless enabled?

    :active
  end

  # The peer's address with no trailing slash, ready to take a path.
  #
  # @return [String, nil]
  def normalized_base_url
    base_url.to_s.strip.chomp("/").presence
  end

  private

  # Each kind is one of our evidence types, the vocabulary both lists filter on.
  def kinds_are_evidence_types
    { import_kinds: import_kinds, export_kinds: export_kinds }.each do |name, kinds|
      unknown = Array(kinds).map(&:to_s) - EvidenceItem::EVIDENCE_TYPES
      errors.add(name, "has unknown types: #{unknown.join(', ')}") if unknown.any?
    end
  end

  # https only, except in development where a local peer is plain http. The
  # address is a prefix the client appends paths to, so it carries no credentials,
  # query or fragment, and (outside development) no private network host.
  def base_url_is_secure
    return if base_url.blank?

    uri = URI.parse(base_url.to_s.strip)
    allowed = uri.scheme == "https" || (uri.scheme == "http" && Rails.env.development?)
    if !allowed || uri.host.blank?
      errors.add(:base_url, "must start with https://")
    elsif uri.userinfo.present? || uri.query.present? || uri.fragment.present?
      errors.add(:base_url, "must be a plain address, with no login, query or fragment")
    elsif !Rails.env.development? && FeedbackExchange::HostGuard.private_host?(uri.host)
      errors.add(:base_url, "must not be a private network address")
    end
  rescue URI::InvalidURIError
    errors.add(:base_url, "is not a valid URL")
  end
end
