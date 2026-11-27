# frozen_string_literal: true

# The structure page's read ([#537](https://github.com/espaliahq/espalia/issues/537)):
# one unit's own structure, for anyone who may change it. Unit names, never a
# person's.
class Operations::OrgGraph::UnitStructure < Operations::Base
  include Operations::OrgGraph::LevelsPayload

  description "Read the structure a unit gives the units beneath it: its unit types, top first, each with " \
              "its provider, how many live units it holds and how many retired units it held (by distinct " \
              "name, the first three of each named), the type ids it can sit under (parent_ids), whether it " \
              "can sit directly under the unit (top) and whether the caller can remove it today. declares is " \
              "false, with no types, for a unit with no structure of its own. For anyone who may change that " \
              "structure: an admin, an Org Graph editor, or someone whose reach covers the unit."
  category :read
  approval :none

  parameter :unit_id, String, required: true, allow_blank: false, schema: { format: "uuid" }

  # @raise [Pundit::NotAuthorizedError] unless the caller may change the unit's structure
  def policy_check
    authorize :org_graph, :show_units?
    policy = Pundit.policy!(context, :org_graph)
    return if policy.edit_structure_of?(unit)

    raise Pundit::NotAuthorizedError, query: :edit_structure_of?, record: :org_graph, policy:
  end

  # @return [Hash] `:unit_id`, `:name`, `:declares` and `:levels`
  # @raise [Operations::Base::ParameterError] for a unit the Org Graph doesn't hold, or one that is retired
  def perform
    levels = OrgTaxonomyLevel.in_structure(unit.id).to_a
    { unit_id: unit.id, name: unit.name, declares: levels.any?, levels: levels_payload(levels, unit.id) }
  end

  private

  def unit
    @unit ||= OrgUnit.find_by(id: params[:unit_id].to_s.downcase).tap do |found|
      raise ParameterError, "unit_id names no unit in the Org Graph" unless found
      raise ParameterError, "#{found.name} is retired" if found.retired?
    end
  end
end
