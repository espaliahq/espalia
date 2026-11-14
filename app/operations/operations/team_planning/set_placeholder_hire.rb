# frozen_string_literal: true

# Adds a hire the HRIS doesn't know yet, or changes one, as a PlaceholderSet
# change [#270](https://github.com/espaliahq/espalia/issues/270): a label and
# the level and FTE they'd join at. A placeholder is not a person, so all
# three seal under the plan's key: forgetting anyone leaves it as it was, and
# deleting the plan shreds it. The map names it by its label, and
# team_planning_set_assignment places it like anyone else.
class Operations::TeamPlanning::SetPlaceholderHire < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  KIND = ::TeamPlanning::Events::PlaceholderSet

  description "Add a placeholder hire to a scenario of a Team Planning plan, or change one, with a label and the " \
              "level and FTE they'd join at. Leave placeholder_id out to add one; the map then lists it as a " \
              "person under that id, named by its label, and team_planning_set_assignment places it. An FTE is " \
              "above 0 and at most 1. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :placeholder_id, String, allow_blank: false, schema: { description: "Omit to add a new placeholder hire." }
  parameter :label, String, required: true, allow_blank: false, schema: { description: "What the plan calls them, such as \"Payments engineer\"." }
  parameter :level, String, allow_blank: false
  parameter :fte, Numeric, schema: { exclusiveMinimum: 0, maximum: 1 }

  # @return [Hash] `{ plan_id, scenario_id, placeholder_id, label, level, fte }`
  def perform
    placeholder_id = params[:placeholder_id].nil? ? SecureRandom.uuid_v7 : uuid!(:placeholder_id)
    end_state = params.slice(:label, :level, :fte).symbolize_keys
    set_change!(KIND, subject_id: placeholder_id, end_state:) do |plan|
      next if params[:placeholder_id].nil? || winning_change(plan, placeholder_id, KIND.facet)

      raise Operations::Base::ParameterError, "This scenario has no such placeholder hire"
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), placeholder_id:, **KIND.end_state(end_state) }
  end
end
