# frozen_string_literal: true

# Base class for shared user-facing operations consumed by both the web
# controllers and the MCP server.
#
# The MCP server and web controllers must dispatch through the same code
# path so functionality stays in lockstep. Each subclass declares its
# input shape, approval routing, category, and the policy check it needs;
# `#call` runs validation → policy → perform in that order.
#
# This is scaffolding only — no concrete subclasses ship in this PR.
# Controllers will migrate to this layer one at a time; until they do,
# the RuboCop cop `GrowthOs/ControllersMustUseOperations` grandfathers
# them via the `Exclude:` list in `.rubocop.yml`.
#
# @example
#   class Operations::Assessments::RateSelf < Operations::Base
#     description "Record or update your own rating for one capability × level."
#     category :write
#     approval :mcp_client
#     parameter :assessment_id,  String, required: true
#     parameter :expectation_id, String, required: true
#     parameter :frequency, String, required: true,
#                                   allowed: %w[none some occasional consistent]
#     parameter :comment, String
#
#     def policy_check
#       authorize Assessment.find(params[:assessment_id]), :rate_self?
#     end
#
#     def perform
#       PersonDevelopment::CommandHandler.new.rate_self(...)
#     end
#   end
#
class Operations::Base
  CATEGORIES = %i[read write destructive].freeze
  APPROVALS  = %i[none mcp_client in_app].freeze

  # Raised when input params fail declared shape/type/allowed-value rules.
  # Distinct from `Pundit::NotAuthorizedError` so callers can map the two
  # to different response codes (4xx vs 403).
  class ParameterError < StandardError; end

  # Describes one declared parameter on an Operation.
  Parameter = Struct.new(:name, :type, :required, :allowed, keyword_init: true) do
    # @param value [Object] the raw value supplied by the caller
    # @return [Object] the validated (un-coerced) value
    # @raise [ParameterError] when missing/required, wrong type, or not in `allowed`
    def validate!(value)
      if value.nil?
        raise ParameterError, "missing required parameter: #{name}" if required

        return nil
      end

      unless value.is_a?(type)
        raise ParameterError, "#{name} must be a #{type}, got #{value.class}"
      end

      if allowed && !allowed.include?(value)
        raise ParameterError, "#{name} must be one of #{allowed.inspect}, got #{value.inspect}"
      end

      value
    end
  end

  # Self-register every concrete subclass into Operations::Registry so the
  # MCP server can list them without an explicit manifest. Anonymous test
  # subclasses are filtered inside the registry.
  def self.inherited(subclass)
    super
    Operations::Registry.register(subclass)
  end

  class << self
    # @return [String, nil] human-readable description used by MCP tool listings.
    def description(text = nil)
      @description = text if text
      @description
    end

    # @return [Symbol] :read | :write | :destructive
    def category(symbol = nil)
      if symbol
        raise ArgumentError, "unknown category #{symbol.inspect}" unless CATEGORIES.include?(symbol)

        @category = symbol
      end
      @category || :read
    end

    # @return [Symbol] :none | :mcp_client | :in_app
    def approval(symbol = nil)
      if symbol
        raise ArgumentError, "unknown approval #{symbol.inspect}" unless APPROVALS.include?(symbol)

        @approval = symbol
      end
      @approval || default_approval_for_category
    end

    # Declares one input parameter.
    #
    # @param name [Symbol]
    # @param type [Class] expected Ruby class
    # @param required [Boolean]
    # @param allowed [Array, nil] enum of allowed values
    def parameter(name, type, required: false, allowed: nil)
      parameters[name.to_sym] = Parameter.new(
        name: name.to_sym, type: type, required: required, allowed: allowed
      )
    end

    # @return [Hash{Symbol=>Parameter}]
    def parameters
      @parameters ||= {}
    end

    # Convenience entry point. Forwards to a new instance's `#call`.
    def call(context:, params: {})
      new(context: context, params: params).call
    end

    private

    # Destructive ops route to in-app approval unless explicitly opted out.
    # Reads and writes default to no extra approval beyond the MCP client's
    # own prompt and the policy check.
    def default_approval_for_category
      category == :destructive ? :in_app : :none
    end
  end

  attr_reader :context, :params

  # @param context [AuthorizationContext]
  # @param params [Hash] raw caller input — validated against declared parameters
  def initialize(context:, params: {})
    @context = context
    @params  = validate_params(params)
  end

  # Run the operation: param-validated already, now policy_check → perform.
  # `perform` is wrapped with {AuditMetadata.wrap_event_store} so any RES
  # events the underlying command handlers publish inherit `acting_via`
  # and (when present) `client_application_id` from the seeded request
  # context — letting us attribute every write to web / MCP / HRIS without
  # threading metadata args through every command handler.
  #
  # @return [Object] whatever `#perform` returns (typically the affected record
  #   id or read-model snapshot)
  # @raise [Pundit::NotAuthorizedError] when `#policy_check` denies
  # @raise [ParameterError] never reached here — params are validated in `#initialize`
  def call
    policy_check
    AuditMetadata.wrap_event_store { perform }
  end

  # Subclasses must implement.
  def policy_check
    raise NotImplementedError, "#{self.class} must implement #policy_check"
  end

  # Subclasses must implement.
  def perform
    raise NotImplementedError, "#{self.class} must implement #perform"
  end

  protected

  # Pundit policy check against the AuthorizationContext.
  #
  # Mirrors `Pundit::Authorization#authorize` but works outside a controller:
  # we hand the context object straight to `Pundit.authorize`, which then
  # forwards it as the policy's user argument.
  #
  # @param record [Object] the resource being authorized
  # @param query [Symbol] policy method (e.g. `:show?`)
  # @raise [Pundit::NotAuthorizedError]
  def authorize(record, query)
    Pundit.authorize(context, record, query)
  end

  private

  # Reduce a raw input hash to the declared parameter set, with validation.
  # Symbolises keys so callers may pass either form (controller params are
  # ActionController::Parameters; MCP input arrives as JSON-parsed string keys).
  def validate_params(raw)
    raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    symbolised = raw.transform_keys(&:to_sym)

    self.class.parameters.each_with_object({}) do |(name, parameter), out|
      out[name] = parameter.validate!(symbolised[name])
    end
  end
end
