# frozen_string_literal: true

# Splits a scenario so the part people agree on can stand, and later be
# approved, alone ([#321](https://github.com/espaliahq/espalia/issues/321)).
# The agreed part takes the scenario's place and the rest sits on it, so
# every scenario resolves as it did.
#
# A refusal for a change the agreed part can't stand without names each such
# change's event id, so the caller can move it across too.
class Operations::TeamPlanning::SplitScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Split a scenario of a Team Planning plan in two, so the part people agree on can stand alone. " \
              "The changes event_ids names, and every earlier change to the same thing, move into a new scenario " \
              "named name, which takes the scenario's place; the scenario keeps the rest, its id and what forks " \
              "from it, and sits 'on' the new one over the same period. Every scenario resolves as before. Take " \
              "event_ids as team_planning_split_needs lists them, the latest change to each subject and facet. Refused " \
              "for an earlier change, which means the scenario changed since it was read, for the baseline, when nothing " \
              "or everything would move, when a moving change needs something only a staying change creates (the refusal names those " \
              "changes' event ids), or unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :event_ids, Array, required: true,
    schema: { type: "array", items: { type: "string" }, minItems: 1, description: "changes or pins in effect in the scenario" }
  parameter :name, String, required: true, allow_blank: false,
    schema: { description: "What the agreed part is, such as 'Agreed Q1 hires'. Don't put a person's name in it." }

  # @return [Hash] `{ plan_id, scenario_id, agreed_id, name, moved_event_ids }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    agreed_id = SecureRandom.uuid_v7
    plan = refusing_bad_plans do
      handler.split_scenario(plan_id, scenario_id, agreed_id:, name: params[:name], event_ids: event_ids!)
    rescue ::TeamPlanning::SplitBlocked => e
      raise Operations::Base::ParameterError, "#{e.message} (event_ids #{e.blocks.map(&:event_id).uniq.join(', ')})"
    end
    { plan_id:, scenario_id:, agreed_id:, name: params[:name].squish, moved_event_ids: plan.log_of(agreed_id).map(&:event_id) }
  end

  private

  def event_ids!
    Array(params[:event_ids]).map do |value|
      next value.downcase if value.is_a?(String) && value.match?(UUID_RE)

      raise Operations::Base::ParameterError, "event_ids must hold event ids, got #{value.inspect}"
    end
  end
end
