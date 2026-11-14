# frozen_string_literal: true

# Which capacity model ({TeamPlanning::CapacityModel}) each role family uses,
# with its parameters, and which roles use another. A role's choice beats its
# family's. Read at a seat's unit, so a unit can choose differently for its
# subtree.
#
# The default chooses nothing, so every seat stays unclassified until a
# tenant or plan says how to count it, rather than being guessed at.
#
# @example
#   { "families" => { engineering_id => { "model" => "per_fte", "params" => {} } },
#     "roles" => { em_role_id => { "model" => "per_fte", "params" => {} } } }
class TeamPlanning::RuleKinds::Capacity < TeamPlanning::RuleKind
  SCOPES = %w[families roles].freeze

  # @return [String]
  def self.rule_name = "capacity_model"

  # @return [String]
  def self.description = "Which capacity model each role family uses, and which roles use another, each with its params"

  # @return [Hash]
  def self.default = { "families" => {}, "roles" => {} }

  # @return [Hash]
  def self.json_schema
    choice = { type: "object", properties: { model: { type: "string" }, params: { type: "object" } }, required: [ "model" ] }
    { type: "object",
      properties: SCOPES.to_h { [ it, { type: "object", description: "#{it == "families" ? "Role family" : "Role"} id => its model", additionalProperties: choice } ] } }
  end

  # @param value [Hash] with string keys
  # @return [Hash] each id downcased, each choice with its params as the model checked them
  # @raise [TeamPlanning::Error] for another key, an unknown model or params it refuses, never naming a param's value
  def self.check(value)
    extra = value.keys - SCOPES
    raise TeamPlanning::Error, "A capacity_model rule takes only #{SCOPES.join(" and ")}, not #{extra.join(", ")}" if extra.any?

    SCOPES.to_h { [ it, choices!(it, value.fetch(it, {})) ] }
  end

  # @param value [Hash] as {.check} stored it
  # @param role_id [String]
  # @param family_id [String, nil]
  # @return [Hash, nil] `{ "model", "params", "chosen_for" }`, chosen_for being "role" or "family"; nil when neither chooses
  def self.choice_for(value, role_id:, family_id:)
    return value["roles"][role_id].merge("chosen_for" => "role") if value.dig("roles", role_id)
    return value["families"][family_id].merge("chosen_for" => "family") if family_id && value.dig("families", family_id)

    nil
  end

  def self.choices!(scope, choices)
    raise TeamPlanning::Error, "A capacity_model rule's #{scope} must be an object" unless choices.is_a?(Hash)

    choices.to_h do |id, choice|
      raise TeamPlanning::Error, "Each of #{scope} must name a model" unless choice.is_a?(Hash) && choice["model"].present?

      extra = choice.keys - %w[model params]
      raise TeamPlanning::Error, "A choice takes only model and params, not #{extra.join(", ")}" if extra.any?

      model = choice["model"].to_s
      [ id.to_s.strip.downcase, { "model" => model, "params" => TeamPlanning::CapacityModels.check(model, choice.fetch("params", {})) } ]
    end
  end

  private_class_method :choices!
end
