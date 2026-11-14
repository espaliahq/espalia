# frozen_string_literal: true

# The kinds of rule a plan may set ({TeamPlanning::RuleKind}). A story that
# adds a kind names its class in {BUILT_IN}.
class TeamPlanning::RuleKinds
  BUILT_IN = [].freeze
  NAME = /\A[a-z][a-z0-9_]*\z/

  @registered = []

  class << self
    # @return [Array<Class<TeamPlanning::RuleKind>>]
    def all = kinds.values

    # @return [Hash{String => Hash}] each rule's built-in default, by rule
    def defaults = kinds.transform_values { it.default.deep_stringify_keys }

    # @param rule [String]
    # @return [Class<TeamPlanning::RuleKind>]
    # @raise [TeamPlanning::Error] for a rule no kind names
    def fetch(rule) = kinds.fetch(rule.to_s) { raise TeamPlanning::Error, "No such rule" }

    # @param rule [String]
    # @param value [Hash]
    # @return [Hash] the value as stored, with string keys
    # @raise [TeamPlanning::Error] for an unknown rule or a value its kind refuses, never naming the value
    def check(rule, value)
      kind = fetch(rule)
      raise TeamPlanning::Error, "A rule's value must be an object" unless value.is_a?(Hash)

      kind.check(value.deep_stringify_keys).deep_stringify_keys
    end

    # Adds a kind outside {BUILT_IN}, for tests.
    #
    # @param kind [Class<TeamPlanning::RuleKind>]
    # @raise [ArgumentError] for a kind {TeamPlanning::RuleKinds} can't hold
    def register(kind)
      @registered |= [ admit!(kind) ]
      kinds
    rescue ArgumentError
      unregister(kind)
      raise
    end

    # @param kind [Class<TeamPlanning::RuleKind>]
    def unregister(kind) = @registered.delete(kind)

    private

    def kinds
      (BUILT_IN.map(&:constantize) + @registered).each_with_object({}) do |kind, by_name|
        name = admit!(kind).rule_name
        raise ArgumentError, "#{kind} names #{name}, which #{by_name[name]} already holds" if by_name.key?(name)

        by_name[name] = kind
      end
    end

    def admit!(kind)
      raise ArgumentError, "#{kind} is not a kind of rule" unless kind.is_a?(Class) && kind < TeamPlanning::RuleKind
      raise ArgumentError, "#{kind} must name its rule in snake_case" unless kind.rule_name.to_s.match?(NAME)
      raise ArgumentError, "#{kind} holds a shreddable value, which waits on shredding: https://github.com/espaliahq/espalia/issues/213" if kind.shreddable?

      kind
    end
  end
end
