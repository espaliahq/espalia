# frozen_string_literal: true

# The capacity models a rule may choose ({TeamPlanning::CapacityModel}). A
# story that adds a model names its class in {BUILT_IN}; a deployment adds
# its own with {.register}.
class TeamPlanning::CapacityModels
  BUILT_IN = %w[TeamPlanning::CapacityModels::PerFte TeamPlanning::CapacityModels::Units].freeze
  NAME = /\A[a-z][a-z0-9_]*\z/

  @registered = []

  class << self
    # @return [Array<Class<TeamPlanning::CapacityModel>>]
    def all = models.values

    # @param model [String]
    # @return [Boolean]
    def registered?(model) = models.key?(model.to_s)

    # @param model [String]
    # @return [Class<TeamPlanning::CapacityModel>]
    # @raise [TeamPlanning::Error] for a model no class names
    def fetch(model) = models.fetch(model.to_s) { raise TeamPlanning::Error, "No such capacity model" }

    # @param model [String]
    # @param params [Hash]
    # @return [Hash] the parameters as stored, with string keys
    # @raise [TeamPlanning::Error] for an unknown model or parameters it refuses, never naming a value
    def check(model, params)
      raise TeamPlanning::Error, "A capacity model's params must be an object" unless params.is_a?(Hash)

      fetch(model).check(params.deep_stringify_keys).deep_stringify_keys
    end

    # @param model [Class<TeamPlanning::CapacityModel>]
    # @raise [ArgumentError] for a model {TeamPlanning::CapacityModels} can't hold
    def register(model)
      @registered |= [ admit!(model) ]
      models
    rescue ArgumentError
      unregister(model)
      raise
    end

    # @param model [Class<TeamPlanning::CapacityModel>]
    def unregister(model) = @registered.delete(model)

    private

    def models
      (BUILT_IN.map(&:constantize) + @registered).each_with_object({}) do |model, by_name|
        name = admit!(model).model_name
        raise ArgumentError, "#{model} names #{name}, which #{by_name[name]} already holds" if by_name.key?(name)

        by_name[name] = model
      end
    end

    def admit!(model)
      raise ArgumentError, "#{model} is not a capacity model" unless model.is_a?(Class) && model < TeamPlanning::CapacityModel
      raise ArgumentError, "#{model} must name its model in snake_case" unless model.model_name.to_s.match?(NAME)

      model
    end
  end
end
