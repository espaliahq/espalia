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
# the RuboCop cop `Espalia/ControllersMustUseOperations` grandfathers
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
  # Value types a `requires_when` match can hold: JSON primitives, so the
  # runtime comparison and the emitted `const`/`enum` mean the same thing.
  MATCHABLE_TYPES = [ String, Integer, Float, TrueClass, FalseClass ].freeze

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

  # Behaviour shared by the two conditional rules (`requires_when` /
  # `forbids_when`): `dependent`'s presence is governed by the `trigger`
  # parameter's validated value landing in `values`. How the rule was declared
  # (`equals:` / `in:`) isn't recorded — a one-value set advertises as `const`
  # and a longer one as `enum`, which say the same thing in JSON Schema.
  #
  # `message` optionally replaces the generic wording — a String, or a callable
  # taking the matched trigger value.
  module ConditionalRule
    # @param value [Object] the trigger parameter's validated value
    # @return [Boolean] whether this rule is armed
    def triggered_by?(value)
      values.include?(value)
    end

    # @param value [Object] the trigger parameter's validated value
    # @return [String] the ParameterError message, naming the value that armed it
    def message_for(value)
      return message.call(value) if message.respond_to?(:call)
      return message if message

      default_message(value)
    end
  end

  # One `requires_when` declaration — `dependent` is mandatory while armed,
  # and pinned to `must_be` when one was declared.
  ConditionalRequirement = Struct.new(:dependent, :trigger, :values, :message, :must_be, keyword_init: true) do
    include ConditionalRule

    # Whether the dependent's validated value satisfies the armed requirement.
    # `must_be` pins it exactly; otherwise it must merely be supplied and
    # non-blank (`false` is a supplied boolean value, not an absence).
    #
    # @param value [Object] the dependent parameter's validated value
    # @return [Boolean]
    def satisfied_by?(value)
      return value == must_be unless must_be.nil?

      value == false || value.present?
    end

    # @param value [Object] the matched trigger value
    # @return [String]
    def default_message(value)
      return "#{dependent} must be #{must_be.inspect} when #{trigger} is #{value.inspect}" unless must_be.nil?

      "#{dependent} is required when #{trigger} is #{value.inspect}"
    end
  end

  # One `forbids_when` declaration — `dependent` must not be supplied while
  # armed. The mirror image of {ConditionalRequirement}.
  ConditionalProhibition = Struct.new(:dependent, :trigger, :values, :message, keyword_init: true) do
    include ConditionalRule

    # @param value [Object] the matched trigger value
    # @return [String]
    def default_message(value)
      "#{dependent} is not accepted when #{trigger} is #{value.inspect}"
    end
  end

  # One `dependent_required` declaration: supplying `dependent` obliges the
  # caller to supply `requires` too. No trigger VALUE is involved, which is why
  # this is a plain pair rather than a {ConditionalRule}.
  DependentRequirement = Struct.new(:dependent, :requires, :message, keyword_init: true) do
    # @return [String] the ParameterError message
    def message_for
      return message.call(dependent) if message.respond_to?(:call)
      return message if message

      "#{requires} is required when #{dependent} is supplied"
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
      return @description if prose_fields.empty?

      [ @description, Prose.mcp_note(*prose_fields) ].compact.join(" ")
    end

    # Declares text parameters that render as Markdown through {Prose}
    # (#482), so the tool description tells clients. Named, because the same
    # tool may also take framework text that stays plain.
    #
    # @param names [Array<Symbol>]
    # @return [Array<Symbol>]
    def prose_fields(*names)
      @prose_fields = names.map(&:to_sym) if names.any?
      @prose_fields || []
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
        name: name.to_sym, type: type, required: required, allowed: allowed,
        schema: normalize_schema_fragment(schema), allow_blank: allow_blank
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
    # A stricter non-blank rule is `allow_blank: false` on the parameter.
    #
    # A present-but-null key (`{"weight": null}`) counts as NOT supplied here,
    # while `required` inside an `anyOf` branch would call it present — but the
    # two don't actually diverge: the property's own declared type rejects null
    # first, so a validating client and this check agree.
    #
    # @param names [Array<Symbol>] at least two declared parameter names
    # @raise [ArgumentError] at load time for an unknown or too-short set
    def requires_any_of(*names)
      # uniq before counting: `requires_any_of :name, :name` would otherwise
      # clear the size check while describing a group of one, quietly making
      # `name` mandatory instead of one of several alternatives.
      names = names.map(&:to_sym).uniq
      raise ArgumentError, "requires_any_of needs at least two parameters" if names.size < 2

      unknown = names - parameters.keys
      raise ArgumentError, "requires_any_of names undeclared parameter(s): #{unknown.join(', ')}" if unknown.any?

      parameter_constraints << names
    end

    # @return [Array<Array<Symbol>>] one entry per `requires_any_of` group
    def parameter_constraints
      @parameter_constraints ||= []
    end

    # Declares that `name` is required only when another parameter carries a
    # particular value — the shape `required:` can't express at all, because it
    # is unconditional.
    #
    #   requires_when :custom_type_label, if: :evidence_type, equals: "other"
    #   requires_when :to_stable_id,      if: :mapping_type,  in: SURVIVOR_TYPES
    #
    # Unlike `requires_any_of` (which asks only whether the key ARRIVED), this
    # demands a value that is actually there: the dependent must be supplied
    # AND non-blank. That is deliberate — every rule this replaced guarded on
    # `blank?`, and a conditionally-required field is conditionally *mandatory*,
    # so `custom_type_label: ""` alongside `evidence_type: "other"` is the very
    # mistake being caught, not a partial-update clear. `false` counts as
    # supplied (a real boolean value, not an absence). The emitted schema says
    # the same thing: the `then` branch carries `required` PLUS the type's
    # non-blank keywords, so a validating client and this check agree.
    #
    # `must_be:` additionally PINS the dependent's value, for the discriminated
    # pairs where one parameter dictates the other's exact value rather than
    # merely its presence:
    #
    #   requires_when :scope_type, if: :role, equals: "role_lead", must_be: "role"
    #
    # The pin replaces the non-blank keywords with `const` (strictly stronger),
    # and the runtime compares for equality — so, again, one declaration governs
    # both the advertised contract and the boundary check.
    #
    # @param name [Symbol] the conditionally-required (dependent) parameter
    # @param if [Symbol] the trigger parameter whose value decides
    # @param equals [Object, nil] trigger value that makes `name` required
    # @param in [Array, nil] trigger values that make `name` required
    # @param must_be [Object, nil] the exact value `name` must then carry
    # @param message [String, #call, nil] replaces the generic parameter-speak
    #   wording — pass a callable to vary it by trigger value. Worth it wherever
    #   the message reaches a user: the web controllers flash `e.message`
    #   verbatim, so a rule with established domain copy keeps it.
    # @raise [ArgumentError] at load time for undeclared parameters, a missing
    #   or doubled match clause, or a value outside the trigger's `allowed:` set
    def requires_when(name, message: nil, must_be: nil, **options)
      parts = conditional_rule_parts("requires_when", name, **options)
      conditional_requirements << ConditionalRequirement.new(
        **parts, message: message,
        must_be: pinned_value("requires_when", parts[:dependent], must_be)
      ).freeze
    end

    # @return [Array<ConditionalRequirement>] one entry per `requires_when`
    def conditional_requirements
      @conditional_requirements ||= []
    end

    # Declares that `name` must NOT be supplied when another parameter carries a
    # particular value — the mirror of `requires_when`, and the shape behind
    # every "X is ignored / not accepted for this Y" rule.
    #
    #   forbids_when :to_stable_id, if: :mapping_type, in: %w[same archived new]
    #
    # **"Supplied" means the key arrived carrying a non-nil value** — the key's
    # mere presence is the violation, not whether its value is meaty. That is
    # exactly what the emitted `then: { not: { required: [name] } }` asks, so the
    # advertised contract and the runtime check say the same thing. It also means
    # a supplied `""` IS rejected: an inapplicable field is one the caller should
    # not send at all, so a web form whose control stays in the DOM must drop the
    # value before dispatching (a normal controller responsibility) rather than
    # submit an empty one. A present-but-null key is the single case where the
    # two could differ — JSON Schema counts it as present — but the property's
    # own declared type rejects null first, so a validating client and this check
    # never actually disagree.
    #
    # @param name [Symbol] the conditionally-forbidden (dependent) parameter
    # @param if [Symbol] the trigger parameter whose value decides
    # @param equals [Object, nil] trigger value that forbids `name`
    # @param in [Array, nil] trigger values that forbid `name`
    # @param message [String, #call, nil] replaces the generic parameter-speak
    #   wording — pass a callable to vary it by trigger value. Worth it wherever
    #   the message reaches a user: the web controllers flash `e.message`
    #   verbatim.
    # @raise [ArgumentError] at load time for undeclared parameters, a missing
    #   or doubled match clause, or a value outside the trigger's `allowed:` set
    def forbids_when(name, message: nil, **options)
      parts = conditional_rule_parts("forbids_when", name, **options)
      conditional_prohibitions << ConditionalProhibition.new(**parts, message: message).freeze
    end

    # @return [Array<ConditionalProhibition>] one entry per `forbids_when`
    def conditional_prohibitions
      @conditional_prohibitions ||= []
    end

    # Declares that supplying `name` obliges the caller to supply `requires`
    # too — a *presence* dependency with no trigger value, which is exactly
    # JSON Schema's `dependentRequired`.
    #
    #   dependent_required :to_stable_id, requires: :mapping_type
    #
    # This closes the hole `requires_when` / `forbids_when` leave open: both arm
    # on the trigger's VALUE, so neither fires when the trigger is ABSENT — and
    # an operation that then ignores the orphaned dependent drops it silently,
    # the very bug those two exist to stop.
    #
    # "Supplied" means the key arrived with a non-nil value, on both sides,
    # matching what `dependentRequired` asks of a JSON instance.
    #
    # @param name [Symbol] the parameter whose presence creates the obligation
    # @param requires [Symbol] the parameter it then obliges
    # @param message [String, #call, nil] replaces the generic wording — a
    #   callable receives the dependent's name
    # @raise [ArgumentError] at load time for undeclared or identical
    #   parameters, or when `requires` is already unconditionally `required:`
    #   (the rule could never bite — a dead constraint, like a match value
    #   outside its trigger's enum)
    def dependent_required(name, requires:, message: nil)
      name = name.to_sym
      requires = requires.to_sym

      unknown = [ name, requires ] - parameters.keys
      if unknown.any?
        raise ArgumentError, "dependent_required names undeclared parameter(s): #{unknown.join(', ')}"
      end
      raise ArgumentError, "dependent_required cannot make a parameter depend on itself" if name == requires

      if parameters[requires].required
        raise ArgumentError,
              "dependent_required requires: #{requires} is already required — the rule can never fire"
      end

      dependent_requirements << DependentRequirement.new(
        dependent: name, requires: requires, message: message
      ).freeze
    end

    # @return [Array<DependentRequirement>] one entry per `dependent_required`
    def dependent_requirements
      @dependent_requirements ||= []
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

    # Shared parsing + guards for `requires_when` / `forbids_when`. The two take
    # the same `if:` + `equals:`/`in:` clause and answer to the same load-time
    # guards; only the rule they build differs (and with it the default message
    # and the emitted `then` branch), so each constructs its own struct in one
    # shot from these parts.
    #
    # @param declaration [String] the DSL name, for error messages
    # @return [Hash] { dependent:, trigger:, values: }
    def conditional_rule_parts(declaration, name, **options)
      trigger = options.fetch(:if) { raise ArgumentError, "#{declaration} needs if: <parameter>" }
      unknown_options = options.keys - %i[if equals in]
      if unknown_options.any?
        raise ArgumentError, "#{declaration} got unknown option(s): #{unknown_options.join(', ')}"
      end

      values  = conditional_match_values(declaration, **options)
      name    = name.to_sym
      trigger = trigger.to_sym

      validate_conditional_rule!(declaration, name, trigger, values)
      { dependent: name, trigger: trigger, values: values }
    end

    # `in:` must be a literal Array — `Array(hash)` would quietly turn it into
    # `[[key, value]]`, a constraint that can never match. The result is
    # deep-frozen (each String as well as the array — a shared string mutated
    # later would change enforcement just like a mutated array) so nothing the
    # caller keeps a reference to can change what is enforced and advertised.
    #
    # @return [Array] the trigger values that arm the rule
    def conditional_match_values(declaration, **options)
      has_equals = options.key?(:equals)
      has_in     = options.key?(:in)
      unless has_equals ^ has_in
        raise ArgumentError, "#{declaration} needs exactly one of equals: or in:"
      end

      return freeze_match_values([ options[:equals] ]) if has_equals

      values = options[:in]
      raise ArgumentError, "#{declaration} in: needs an Array of values" unless values.is_a?(Array)
      raise ArgumentError, "#{declaration} in: needs at least one value" if values.empty?

      freeze_match_values(values)
    end

    # A `schema:` fragment may be authored with String or Symbol keys — both
    # are ordinary JSON Schema — so it is symbolised HERE, at declaration time,
    # leaving the descriptor's merge a plain one. Skip it and a String-keyed
    # `"type"` lands ALONGSIDE the derived Symbol-keyed `:type`, serialising as
    # a duplicate JSON key.
    #
    # `deep_symbolize_keys` returns fresh containers, so freezing them can't
    # reach anything the caller still holds — worth doing because a fragment is
    # often a shared constant (`ExternalReference.json_schema`) and a later
    # mutation would silently change what is advertised. Strings inside ARE
    # shared, so they are deliberately left alone.
    #
    # @return [Hash, nil]
    def normalize_schema_fragment(fragment)
      return nil if fragment.nil?

      deep_freeze_containers(fragment.deep_symbolize_keys)
    end

    def deep_freeze_containers(value)
      case value
      when Hash  then value.each_value { |nested| deep_freeze_containers(nested) }.freeze
      when Array then value.each { |nested| deep_freeze_containers(nested) }.freeze
      else value
      end
    end

    def freeze_match_values(values)
      values.map { |value| freeze_value(value) }.freeze
    end

    # A String is duped before freezing: the caller's own reference must stay
    # mutable, while what is enforced and advertised cannot change after load.
    def freeze_value(value)
      value.is_a?(String) ? value.dup.freeze : value
    end

    # `must_be:` faces the same guards as a trigger match — it is published as
    # the dependent's `const`, so it must be a JSON primitive and, when the
    # dependent declares an enum, a value it can actually hold. It additionally
    # must fit the dependent's declared TYPE, which a trigger match gets for
    # free from the enum check.
    #
    # @return [Object, nil] the frozen pin, or nil when none was declared
    def pinned_value(declaration, name, must_be)
      return nil if must_be.nil?

      # Publishability first, so a Symbol pin reports the same "JSON primitives"
      # problem a Symbol trigger match does rather than a type mismatch.
      validate_publishable_values!(declaration, "must_be value", name, [ must_be ])

      type = parameters[name].type
      unless pin_matches_type?(type, must_be)
        raise ArgumentError,
              "#{declaration} must_be: #{must_be.inspect} is not a #{type} — #{name} could never carry it"
      end

      freeze_value(must_be)
    end

    # A pin the dependent's declared type can never hold is a dead rule that
    # also publishes a self-contradictory schema (`{type: "integer", const:
    # "5"}`). `Numeric` covers Integer and Float by `is_a?`; `:boolean` is the
    # sentinel for Ruby's missing Boolean class.
    def pin_matches_type?(type, value)
      return [ true, false ].include?(value) if type == :boolean

      value.is_a?(type)
    end

    # Expressible as a JSON Schema `const`/`enum` entry AND comparable to a
    # validated parameter value. Non-finite Floats pass the Float type check but
    # have no JSON encoding (RFC 8259 forbids NaN/Infinity).
    def json_primitive?(value)
      MATCHABLE_TYPES.any? { |type| value.is_a?(type) } &&
        !(value.is_a?(Float) && !value.finite?)
    end

    # Load-time guards: both parameters must exist and differ, every matched
    # value must be a JSON primitive the schema can name, and — when the trigger
    # declares an enum — one it can actually hold (a typo'd value would
    # otherwise declare a rule that can never fire).
    def validate_conditional_rule!(declaration, name, trigger, values)
      unknown = [ name, trigger ] - parameters.keys
      if unknown.any?
        raise ArgumentError, "#{declaration} names undeclared parameter(s): #{unknown.join(', ')}"
      end
      raise ArgumentError, "#{declaration} cannot make a parameter depend on itself" if name == trigger

      validate_publishable_values!(declaration, "match values", trigger, values)
    end

    # Shared by trigger matches and `must_be:` pins, so their wording can't
    # fork. A value must be expressible as a JSON Schema `const`/`enum` entry
    # AND comparable to the validated parameter value. `nil` fails both ways:
    # as a trigger match it would arm the rule when the trigger is ABSENT,
    # which the emitted `if` (whose `required` names the trigger) cannot say. A
    # Symbol looks right in Ruby but desyncs the two — `:other != "other"` at
    # runtime, while the schema would publish the string. And a value outside
    # the parameter's own enum declares a rule that can never fire.
    #
    # @param clause [String] which DSL clause is being validated, for the message
    # @param name [Symbol] the parameter whose `allowed:` set applies
    def validate_publishable_values!(declaration, clause, name, values)
      # `unless invalid.empty?`, never `if invalid.any?` — the values this
      # rejects include nil and false, and a blockless `any?` asks for a
      # truthy element (`[nil].any?` is false).
      invalid = values.reject { |value| json_primitive?(value) }
      unless invalid.empty?
        raise ArgumentError,
              "#{declaration} #{clause} must be JSON primitives (String, number, true/false); " \
              "got #{invalid.inspect}"
      end

      allowed = parameters[name].allowed
      return unless allowed

      outside = values - allowed
      return if outside.empty?

      raise ArgumentError,
            "#{declaration} #{clause} #{outside.inspect} is outside #{name}'s allowed set #{allowed.inspect}"
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
    validate_conditional_requirements!(validated)
    validate_conditional_prohibitions!(validated)
    validate_dependent_requirements!(validated)
    validated
  end

  # Enforce each `dependent_required` declaration: supplying one parameter
  # obliges the other. Runs with the per-parameter checks (before policy_check),
  # like every other input rule.
  #
  # @param validated [Hash{Symbol=>Object}]
  # @raise [ParameterError] when the obliged parameter is absent
  def validate_dependent_requirements!(validated)
    self.class.dependent_requirements.each do |rule|
      next unless supplied_at_all?(validated[rule.dependent])
      next if supplied_at_all?(validated[rule.requires])

      raise ParameterError, rule.message_for
    end
  end

  # Enforce each `requires_any_of` group. Runs with the per-parameter checks
  # (before policy_check), so a malformed call is rejected the same way whether
  # it breaks a single parameter's rule or a cross-parameter one.
  #
  # @param validated [Hash{Symbol=>Object}]
  # @raise [ParameterError] when a group has no parameter supplied
  def validate_parameter_constraints!(validated)
    self.class.parameter_constraints.each do |names|
      next if names.any? { |name| supplied_at_all?(validated[name]) }

      raise ParameterError, "provide at least one of: #{names.join(', ')}"
    end
  end

  # Enforce each `requires_when` declaration: when the trigger holds a matched
  # value, the dependent must carry a real one — the exact `must_be` value when
  # one was pinned. Runs with the per-parameter checks (before policy_check),
  # like every other input rule.
  #
  # @param validated [Hash{Symbol=>Object}]
  # @raise [ParameterError] when an armed requirement's dependent is absent,
  #   blank, or off its pinned value
  def validate_conditional_requirements!(validated)
    self.class.conditional_requirements.each do |requirement|
      trigger_value = validated[requirement.trigger]
      next unless requirement.triggered_by?(trigger_value)
      next if requirement.satisfied_by?(validated[requirement.dependent])

      raise ParameterError, requirement.message_for(trigger_value)
    end
  end

  # Enforce each `forbids_when` declaration: when the trigger holds a matched
  # value, the dependent must be absent. Runs with the per-parameter checks
  # (before policy_check), like every other input rule.
  #
  # @param validated [Hash{Symbol=>Object}]
  # @raise [ParameterError] when an armed prohibition's dependent was supplied
  def validate_conditional_prohibitions!(validated)
    self.class.conditional_prohibitions.each do |prohibition|
      trigger_value = validated[prohibition.trigger]
      next unless prohibition.triggered_by?(trigger_value)
      next unless supplied_at_all?(validated[prohibition.dependent])

      raise ParameterError, prohibition.message_for(trigger_value)
    end
  end

  # "Supplied" as JSON Schema's `required` / `dependentRequired` / `not:
  # required` all read it: the key arrived carrying anything other than nil.
  # Shared by `requires_any_of`, `forbids_when`, and `dependent_required` —
  # every declaration whose emitted schema asks about the property EXISTING, so
  # a blank string counts as supplied for all three. `requires_when` is the odd
  # one out and asks for a non-blank value instead (see
  # `ConditionalRequirement#satisfied_by?`), because its `then` branch carries
  # the non-blank keywords too.
  def supplied_at_all?(value)
    !value.nil?
  end
end
