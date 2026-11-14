# frozen_string_literal: true

# Which on-cost model ({TeamPlanning::OnCostModel}) prices what a seat costs
# on top of its base pay, with its params. Read at a seat's unit, so a unit
# can price its subtree differently.
#
# The default adds nothing, so a plan costs base pay alone until a tenant or
# plan says otherwise.
#
# @example
#   { "model" => "by_country", "params" => { "percents" => { "Atlantis" => "14" }, "otherwise" => "10" } }
class TeamPlanning::RuleKinds::OnCost < TeamPlanning::RuleKind
  # @return [String]
  def self.rule_name = "on_cost"

  # @return [String]
  def self.description = "What a seat costs on top of its base pay: #{TeamPlanning::OnCostModels.all.map { "#{it.model_name} (#{it.description.downcase})" }.join("; ")}"

  # @return [Hash]
  def self.default = { "model" => "flat", "params" => { "percent" => "0" } }

  # @return [Hash]
  def self.json_schema
    { type: "object",
      oneOf: TeamPlanning::OnCostModels.all.map do |model|
        { properties: { model: { const: model.model_name }, params: model.params_schema }, required: %w[model params] }
      end }
  end

  # @param value [Hash] with string keys
  # @return [Hash] the model and its params as the model checked them
  # @raise [TeamPlanning::Error] for another key, an unknown model or params it refuses, never naming a value
  def self.check(value)
    extra = value.keys - %w[model params]
    raise TeamPlanning::Error, "An on_cost rule takes only model and params, not #{extra.join(", ")}" if extra.any?
    raise TeamPlanning::Error, "An on_cost rule must name a model" if value["model"].blank?
    raise TeamPlanning::Error, "An on_cost rule must give its model's params" unless value.key?("params")

    model = value["model"].to_s
    { "model" => model, "params" => TeamPlanning::OnCostModels.check(model, value["params"]) }
  end

  # @param value [Hash] as {.check} stored it
  # @return [TeamPlanning::OnCostModel::Figure]
  # @see TeamPlanning::OnCostModel.on_cost_of
  def self.on_cost_of(value, base:, currency:, country:, share: 1r)
    TeamPlanning::OnCostModels.fetch(value["model"]).on_cost_of(base.to_r, currency:, country:, share: share.to_r, params: value["params"])
  end
end
