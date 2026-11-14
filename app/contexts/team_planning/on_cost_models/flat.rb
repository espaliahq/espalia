# frozen_string_literal: true

# One percentage of base pay, wherever the seat sits.
#
# @example params
#   { "percent" => "12.5" }
class TeamPlanning::OnCostModels::Flat < TeamPlanning::OnCostModel
  # @return [String]
  def self.model_name = "flat"

  # @return [String]
  def self.description = "One percentage of base pay, wherever the seat sits"

  # @return [Hash]
  def self.params_schema = { type: "object", properties: { percent: { type: "string", description: "Such as 12.5" } }, required: [ "percent" ] }

  # @param params [Hash]
  # @return [Hash]
  # @raise [TeamPlanning::Error] for another param, or a percent that isn't one
  def self.check(params)
    extra = params.keys - %w[percent]
    raise TeamPlanning::Error, "A flat on-cost takes only percent, not #{extra.join(", ")}" if extra.any?

    { "percent" => percent!(params["percent"], "A flat on-cost's percent") }
  end

  # @return [TeamPlanning::OnCostModel::Figure]
  def self.on_cost_of(base, currency:, country:, share:, params:)
    amount = base * fraction(params["percent"])
    Figure.new(amount:, working: [ Step.new(label: "#{shown(params["percent"])} of base pay", amount:) ])
  end
end
