# frozen_string_literal: true

# Removes a level from the tenant's taxonomy once no unit holds it, dated on
# or after the day after the last day one did. Earlier days keep it, so
# history still reads it by name.
class Operations::OrgGraph::RemoveLevel < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Remove a level from the Org Graph's taxonomy, from effective_on (today by default). A level " \
              "goes once no unit, retired units included, holds it on that date or after; reading an earlier " \
              "date still shows it. The refusal names the units that hold it, or the last day one did. " \
              "A level an HRIS provides is handed back to Espalia first. A level a live plan places a unit " \
              "at stays until the plan changes or is archived. " \
              "The organisation's structure needs a tenant admin or an Org Graph editor; a unit's own structure " \
              "also admits an owner of that unit or a unit above it, and anyone above them in the reporting line."
  category :destructive
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :structure_unit_id, String, allow_blank: false,
            schema: { format: "uuid", description: "a unit with a structure of its own, to change its unit types; the organisation's structure by default" }

  # @return [Hash] `{ level_id, name, effective_on, levels }`, levels top first
  def perform
    # The aggregate refuses this too, but knows the provider only by its id.
    level = current_levels.find { |candidate| candidate.id == params[:level_id].to_s.downcase }
    if level && level.provider != ::OrgGraph::StructureAggregate::ESPALIA
      raise Operations::Base::ParameterError,
            "#{level.name} comes from #{HrisConfig.provider_label(level.provider)}; hand it back to Espalia before removing it"
    end

    ActiveRecord::Base.transaction do
      ::OrgGraph::Repository.new.lock_structure # a plan places units under it too, so the count holds
      ensure_no_live_plan_holds!(level)
      refusing_as_parameter_errors { structure_handler.remove_level(params[:level_id], effective_on:, **in_structure) }
    end
    { level_id: params[:level_id].to_s.downcase, name: level&.name, **in_structure, effective_on:, levels: levels_payload }
  end

  private

  # Plans live outside the Org Graph, so its aggregate can't see them; this
  # operation is the only way a level is removed. Plan names stay with their
  # members, so the refusal counts the plans rather than naming them. Only
  # units a plan created count: an Org Graph unit's type is checked above, as
  # "no unit holds it".
  def ensure_no_live_plan_holds!(level)
    return unless level

    plans = ProjectionVersion.unless_rebuilding(TeamPlanning::Projections::Overrides::PROJECTION_NAME,
                                                ::OrgGraph::Projections::Structure::PROJECTION_NAME) do
      TeamPlanningOverride.live_plans_by_level([ level.id ]).fetch(level.id, 0)
    end
    return if plans.zero?

    advice = plans == 1 ? "Change or archive that plan first, or delete it if no one can edit it any more" :
                          "Change or archive those plans first, or delete any no one can edit any more"
    raise Operations::Base::ParameterError,
          "#{level.name} can't be removed, as #{plans} live #{'plan'.pluralize(plans)} " \
          "#{plans == 1 ? 'places' : 'place'} units of this type. #{advice}"
  end
end
