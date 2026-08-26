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

  # Raised when a non-read Operation is invoked during an impersonation
  # session. Impersonation ("view as another user") is read-only; the web
  # controller boundary blocks unsafe HTTP methods, and this is the domain
  # backstop in case a write reaches an Operation another way. Detected via
  # {AuditMetadata}'s `impersonator_id`, which the request boundary seeds
  # whenever impersonation is active.
  class ImpersonationReadOnlyError < StandardError; end

  # Describes one declared parameter on an Operation.
  #
  # `schema` is an optional JSON Schema fragment used ONLY for the
  # advertised MCP tool schema (e.g. the object shape of a Hash param so
  # clients see the accepted keys instead of a bare free-form object).
  # Runtime validation still uses `type`/`allowed` — `schema` documents
  # the wire shape, it does not enforce it; the Operation validates a
  # complex param's contents in `perform`.
  Parameter = Struct.new(:name, :type, :required, :allowed, :schema, :allow_blank, keyword_init: true) do
    # Boolean-ish strings accepted for a `:boolean` parameter. MCP clients send
    # JSON true/false; web forms submit strings ("1"/"0" from checkboxes,
    # "true"/"false" from selects) — both surfaces share one Operation, so the
    # cast lives here. Anything outside this table is rejected, never coerced
    # (ActiveModel's everything-truthy cast would turn "banana" into true).
    BOOLEAN_CASTS = {
      true => true, false => false,
      "true" => true, "false" => false, "1" => true, "0" => false,
      "t" => true, "f" => false, "on" => true, "off" => false
    }.freeze

    # @param value [Object] the raw value supplied by the caller
    # @return [Object] the validated value (cast only for `:boolean`)
    # @raise [ParameterError] when missing/required, wrong type, or not in `allowed`
    def validate!(value)
      if value.nil?
        raise ParameterError, "missing required parameter: #{name}" if required

        return nil
      end

      return validate_boolean!(value) if type == :boolean

      unless value.is_a?(type)
        raise ParameterError, "#{name} must be a #{type}, got #{value.class}"
      end

      # A supplied-but-blank string, for a field where blank means nothing.
      # Distinct from `required`: the key may be omitted entirely (a partial
      # update), but sending "" is a mistake, not a request to clear.
      if allow_blank == false && value.respond_to?(:blank?) && value.blank?
        raise ParameterError, "#{name} can't be blank"
      end

      if allowed && !allowed.include?(value)
        raise ParameterError, "#{name} must be one of #{allowed.inspect}, got #{value.inspect}"
      end

      value
    end

    # @param value [Object]
    # @return [Boolean]
    # @raise [ParameterError] when the value isn't recognisably boolean
    def validate_boolean!(value)
      key = value.is_a?(String) ? value.downcase : value
      BOOLEAN_CASTS.fetch(key) do
        raise ParameterError, "#{name} must be a boolean, got #{value.inspect}"
      end
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
    # @param type [Class, Symbol] expected Ruby class, or `:boolean` — Ruby has
    #   no Boolean class, so the sentinel accepts true/false (and casts the
    #   boolean-ish strings web forms submit; see Parameter::BOOLEAN_CASTS)
    # @param required [Boolean]
    # @param allowed [Array, nil] enum of allowed values
    # @param schema [Hash, nil] explicit JSON Schema fragment for the
    #   advertised MCP tool schema (overrides the default type mapping —
    #   use for complex Hash/Array params whose shape clients need to see)
    # @param allow_blank [Boolean] when false, a supplied "" is rejected.
    #   Use for a field where blank carries no meaning (a name, an id) —
    #   NOT for one where "" is a legitimate clear (a description).
    def parameter(name, type, required: false, allowed: nil, schema: nil, allow_blank: true)
      parameters[name.to_sym] = Parameter.new(
        name: name.to_sym, type: type, required: required, allowed: allowed, schema: schema,
        allow_blank: allow_blank
      )
    end

    # @return [Hash{Symbol=>Parameter}]
    def parameters
      @parameters ||= {}
    end

    # Declares that the caller must supply AT LEAST ONE of `names` — a
    # constraint between parameters, which the per-parameter `required:` flag
    # can't express (it yields a flat "all of these" list).
    #
    # "Supplied" means **the key was sent at all** (non-nil), deliberately NOT
    # `present?`. That is exactly what the emitted JSON Schema means
    # (`anyOf: [{required: [a]}, {required: [b]}]` asks whether the key is
    # there, not whether its value is meaty), so the advertised contract and
    # the runtime check say the same thing — the whole point of declaring it.
    # It is also the semantics partial updates need: `department: ""` is a
    # meaningful clear, and `is_entry: false` / `weight: 0` are real values.
    # An operation wanting a stricter non-blank rule keeps its own check —
    # JSON Schema `required` cannot express that either way.
    #
    # @param names [Array<Symbol>] at least two declared parameter names
    # @raise [ArgumentError] at load time for an unknown or too-short set
    def requires_any_of(*names)
      names = names.map(&:to_sym)
      raise ArgumentError, "requires_any_of needs at least two parameters" if names.size < 2

      unknown = names - parameters.keys
      raise ArgumentError, "requires_any_of names undeclared parameter(s): #{unknown.join(', ')}" if unknown.any?

      parameter_constraints << names
    end

    # @return [Array<Array<Symbol>>] one entry per `requires_any_of` group
    def parameter_constraints
      @parameter_constraints ||= []
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
    forbid_impersonated_write!
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
  # @param policy_class [Class, nil] overrides the inferred policy class —
  #   matches the controller-side `authorize record, query, policy_class: X`
  #   call shape (used e.g. when EvidencePolicy authorizes an
  #   PersonFrameworkAssignment record).
  # @raise [Pundit::NotAuthorizedError]
  def authorize(record, query, policy_class: nil)
    Pundit.authorize(context, record, query, policy_class: policy_class)
  end

  private

  # Domain backstop for read-only impersonation: refuse any non-read
  # Operation while an impersonation session is active. `:none`-approval
  # reads pass; everything else raises. The signal is {AuditMetadata}'s
  # `impersonation_active` flag, seeded only on web requests where a tenant
  # admin is impersonating — MCP/HRIS never set it, so this is a no-op
  # there. We consult the flag rather than `impersonator_id` so the guard
  # still fires when the real admin has no linked Person (nil id).
  def forbid_impersonated_write!
    return if self.class.category == :read
    return unless AuditMetadata.current[:impersonation_active]

    raise ImpersonationReadOnlyError,
          "#{self.class} is a #{self.class.category} operation and cannot run while impersonating"
  end

  # Reduce a raw input hash to the declared parameter set, with validation.
  # Symbolises keys so callers may pass either form (controller params are
  # ActionController::Parameters; MCP input arrives as JSON-parsed string keys).
  def validate_params(raw)
    raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    symbolised = raw.transform_keys(&:to_sym)

    validated = self.class.parameters.each_with_object({}) do |(name, parameter), out|
      out[name] = parameter.validate!(symbolised[name])
    end
    validate_parameter_constraints!(validated)
    validated
  end

  # Enforce each `requires_any_of` group. Runs with the per-parameter checks
  # (before policy_check), so a malformed call is rejected the same way whether
  # it breaks a single parameter's rule or a cross-parameter one.
  #
  # @param validated [Hash{Symbol=>Object}]
  # @raise [ParameterError] when a group has no parameter supplied
  def validate_parameter_constraints!(validated)
    self.class.parameter_constraints.each do |names|
      next if names.any? { |name| !validated[name].nil? }

      raise ParameterError, "provide at least one of: #{names.join(', ')}"
    end
  end
end
