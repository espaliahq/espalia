# frozen_string_literal: true

# Removes a level from the tenant's taxonomy that no unit has ever held.
class Operations::OrgGraph::RemoveLevel < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Remove a level from the Org Graph's taxonomy, from effective_on (today by default). Only a " \
              "level no unit has ever held, retired units included, can go; the refusal names the units. " \
              "A level an HRIS provides is handed back to Espalia first. A level a live plan places a unit " \
              "at stays until the plan changes or is archived. Refused unless the caller is a tenant admin."
  category :destructive
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false

  # @return [Hash] `{ level_id, name, effective_on, levels }`, levels top first
  def perform
    # The aggregate refuses this too, but knows the provider only by its id.
    level = current_levels.find { |candidate| candidate.id == params[:level_id].to_s.downcase }
    if level && level.provider != ::OrgGraph::StructureAggregate::ESPALIA
      raise Operations::Base::ParameterError,
            "#{level.name} comes from #{HrisConfig.provider_label(level.provider)}; hand it back to Espalia before removing it"
    end

    ensure_no_live_plan_holds!(level)
    refusing_as_parameter_errors { structure_handler.remove_level(params[:level_id], effective_on:) }
    { level_id: params[:level_id].to_s.downcase, name: level&.name, effective_on:, levels: levels_payload }
  end

  private

  # Plans live outside the Org Graph, so its aggregate can't see them; this
  # operation is the only way a level is removed. Plan names stay with their
  # members, so the refusal counts the plans rather than naming them.
  def ensure_no_live_plan_holds!(level)
    return unless level

    plans = TeamPlanningOverride.where(plan_id: TeamPlanningPlan.live.select(:id), kind: TeamPlanning::Events::UnitSet.name)
                                .where("end_state ->> 'level_id' = ?", level.id).distinct.count(:plan_id)
    return if plans.zero?

    raise Operations::Base::ParameterError,
          "#{level.name} can't be removed, as #{plans} live #{'plan'.pluralize(plans)} #{plans == 1 ? 'places' : 'place'} " \
          "units of this type. Change or archive #{plans == 1 ? 'that plan' : 'those plans'} first"
  end
end
