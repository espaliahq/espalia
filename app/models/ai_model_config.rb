# frozen_string_literal: true

# Which model answers for a tenant's AI features, stored in Tenant.ai_config
# JSONB. Today that is placement suggestions for feedback.
#
# The stored shape is generic: a provider kind, an optional address, a model
# id. "Vercel AI Gateway" is a form preset that fills a provider kind, the
# gateway's address and a model id, nothing more; no adapter special-cases it.
#
# Holds nothing secret: the API key lives in the encrypted `ai_credentials`
# column (see {Tenant#ai_secrets}).
#
# @example
#   tenant.ai_config.provider          # => "openai_compatible"
#   tenant.ai_config.configured?(tenant) # => true
class AiModelConfig
  include StoreModel::Model

  # anthropic: the Anthropic API, or any Anthropic-compatible endpoint.
  # openai_compatible: anything that serves POST {base_url}/chat/completions.
  # typesafe_jev: TypeSafe AI's Jev decision model at POST {base_url}/evaluate.
  PROVIDERS = %w[anthropic openai_compatible typesafe_jev].freeze
  EFFORTS = %w[low medium high xhigh max].freeze
  DEFAULT_ANTHROPIC_MODEL = "claude-opus-5-5"
  VERCEL_AI_GATEWAY_URL = "https://ai-gateway.vercel.sh/v1"
  JEV_MODEL = "typesafe-ai/jev"
  MODEL_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/

  # Form presets. Choosing one fills the fields; nothing about it is stored.
  PRESETS = {
    "anthropic" => { label: "Anthropic API", provider: "anthropic", base_url: nil, model: DEFAULT_ANTHROPIC_MODEL },
    "vercel_ai_gateway" => { label: "Vercel AI Gateway: Jev (TypeSafe AI)", provider: "typesafe_jev",
                             base_url: VERCEL_AI_GATEWAY_URL, model: JEV_MODEL },
    "vercel_ai_gateway_chat" => { label: "Vercel AI Gateway: a chat model", provider: "openai_compatible",
                                  base_url: VERCEL_AI_GATEWAY_URL, model: "anthropic/claude-opus-5-5" },
    "openai_compatible" => { label: "Other OpenAI-compatible endpoint", provider: "openai_compatible", base_url: nil, model: nil },
    "anthropic_compatible" => { label: "Other Anthropic-compatible endpoint", provider: "anthropic", base_url: nil, model: nil }
  }.freeze

  attribute :provider, :string, default: "anthropic"
  attribute :base_url, :string
  attribute :model, :string
  attribute :suggestions_enabled, :boolean, default: false
  attribute :pseudonymise_names, :boolean, default: true
  attribute :effort, :string, default: "low"

  validates :provider, inclusion: { in: PROVIDERS }
  validates :effort, inclusion: { in: EFFORTS }, allow_blank: true
  validates :base_url, :model, presence: true, unless: :anthropic?
  validates :model, format: { with: MODEL_FORMAT, message: "may only contain letters, numbers and . _ : / @ + -" },
                    length: { maximum: 200 }, allow_blank: true
  validate :base_url_is_secure

  # The labels the settings form uses, so an error names the field the admin sees.
  ATTRIBUTE_LABELS = { "base_url" => "Address", "model" => "Model", "effort" => "Effort" }.freeze

  # @return [String]
  def self.human_attribute_name(attribute, options = {})
    ATTRIBUTE_LABELS.fetch(attribute.to_s) { super }
  end

  # @return [Boolean]
  def openai_compatible? = provider == "openai_compatible"

  # @return [Boolean]
  def anthropic? = provider == "anthropic"

  # @return [Boolean] a decision model, which answers typed questions with
  #   probabilities and writes no prose
  def typesafe_jev? = provider == "typesafe_jev"

  # The address with no trailing slash, ready to take a path.
  #
  # @return [String, nil]
  def normalized_base_url
    base_url.to_s.strip.chomp("/").presence
  end

  # The host alone, for display: an address may carry a path prefix that is
  # nobody's business on a status page.
  #
  # @return [String, nil]
  def base_host
    URI.parse(base_url.to_s.strip).host.presence
  rescue URI::InvalidURIError
    nil
  end

  # Whether a request can be built: the endpoint is complete and a key is stored.
  #
  # @param tenant [Tenant] the parent tenant, which holds the key
  # @return [Boolean]
  def configured?(tenant)
    valid? && tenant.ai_api_key.present?
  end

  # Where the AI model stands, from least to most set up.
  #
  # @param tenant [Tenant] the parent tenant, which holds the key
  # @return [Symbol] :not_configured, :disabled or :active
  def state(tenant)
    return :not_configured unless configured?(tenant)
    return :disabled unless suggestions_enabled?

    :active
  end

  private

  # https only, except in development where a local model server is plain
  # http. The address is a prefix the adapters append paths to, so it carries
  # no credentials, query or fragment, and (outside development) no private
  # network host.
  def base_url_is_secure
    return if base_url.blank?

    uri = URI.parse(base_url.to_s.strip)
    allowed = uri.scheme == "https" || (uri.scheme == "http" && Rails.env.development?)
    if !allowed || uri.host.blank?
      errors.add(:base_url, "must start with https://")
    elsif uri.userinfo.present? || uri.query.present? || uri.fragment.present?
      errors.add(:base_url, "must be a plain address, with no login, query or fragment")
    elsif !Rails.env.development? && Ai::HostGuard.private_host?(uri.host)
      errors.add(:base_url, "must not be a private network address")
    end
  rescue URI::InvalidURIError
    errors.add(:base_url, "is not a valid URL")
  end
end
