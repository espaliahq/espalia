# frozen_string_literal: true

# The on-cost models the `on_cost` rule may choose ({TeamPlanning::OnCostModel}).
# A story that adds a model names its class in {BUILT_IN}.
class TeamPlanning::OnCostModels
  BUILT_IN = %w[TeamPlanning::OnCostModels::Flat TeamPlanning::OnCostModels::ByCountry TeamPlanning::OnCostModels::Itemised].freeze

  class << self
    # @return [Array<Class<TeamPlanning::OnCostModel>>]
    def all = models.values

    # @param model [String]
    # @return [Class<TeamPlanning::OnCostModel>]
    # @raise [TeamPlanning::Error] for a model no class names
    def fetch(model) = models.fetch(model.to_s) { raise TeamPlanning::Error, "No such on-cost model" }

    # @param model [String]
    # @param params [Hash]
    # @return [Hash] the params as stored, with string keys
    # @raise [TeamPlanning::Error] for an unknown model or params it refuses, never naming a value
    def check(model, params)
      raise TeamPlanning::Error, "An on-cost model's params must be an object" unless params.is_a?(Hash)

      fetch(model).check(params.deep_stringify_keys).deep_stringify_keys
    end

    private

    def models
      BUILT_IN.map(&:constantize).each_with_object({}) do |model, by_name|
        raise ArgumentError, "#{model} names #{model.model_name}, which #{by_name[model.model_name]} already holds" if by_name.key?(model.model_name)

        by_name[model.model_name] = model
      end
    end
  end
end
