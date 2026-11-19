# frozen_string_literal: true

# Moves a unit Espalia holds beneath another unit, or to the top.
class Operations::OrgGraph::MoveUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite
  prepend Operations::OrgGraph::PlanWrite

  description "Move a unit in the Org Graph beneath another live unit of a kind its own kind can sit " \
              "under, or to the top when parent_id is omitted and its kind can sit there, from effective_on (today by default). Only a unit Espalia holds " \
              "can be moved here. Moving a unit changes who inherits its ownership, so the caller needs " \
              "rights on the unit and where it lands. To move a unit into another structure (into a unit's own " \
              "structure, out of one into the organisation's, or between two), pass conversion: a type of the " \
              "structure it joins for each type the unit and those beneath it hold. Each changes type in the same " \
              "change, and a unit with a structure of its own takes it along, nested. That needs a tenant admin."
  approval :in_app

  CONVERSION_SCHEMA = {
    type: "object", additionalProperties: { type: "string", format: "uuid" },
    description: "each level_id the unit or a unit beneath it holds => the level_id it becomes, a type of the " \
                 "structure it moves into"
  }.freeze

  parameter :unit_id, String, required: true
  parameter :parent_id, String, allow_blank: false
  parameter :conversion, Hash, schema: CONVERSION_SCHEMA, allow_blank: false

  # Checks the conversion here, so MCP saves no approval for one that can't run.
  #
  # @param context [AuthorizationContext]
  # @param params [Hash]
  # @raise [Operations::Base::ParameterError] when the conversion is malformed
  def initialize(context:, params: {})
    super
    ensure_conversion_well_formed!
  end

  # @return [Hash] `{ unit_id, parent_id, effective_on }`, and the conversion when given, as level_id => level_id
  def perform
    return move_across_structures unless conversion_option.empty?

    unit = live_unit!(:unit_id)
    parent = params[:parent_id] && live_unit!(:parent_id)
    on = effective_on
    structure_handler.move_unit(unit.id, parent&.id, effective_on: on, **plan)
    { unit_id: unit.id, parent_id: parent&.id, effective_on: on }
  end

  private

  # A Structure rebuild empties org_units, so this path never reads them: the
  # command names a unit it can't find from its own state, under its lock.
  def move_across_structures
    unit_id = uuid!(:unit_id).downcase
    parent_id = params[:parent_id] && uuid!(:parent_id).downcase
    on = effective_on
    refusing_as_parameter_errors do
      structure_handler.move_unit(unit_id, parent_id, effective_on: on, **conversion_option, **plan)
    rescue OrgGraph::StructureAggregate::UnitUnavailable => e
      raise Operations::Base::ParameterError, unavailable_message(e)
    end
    { unit_id:, parent_id:, effective_on: on, **conversion_option }
  end

  def unavailable_message(error)
    return "#{error.retired_name} is retired" if error.retired_name

    "#{error.role == :parent ? :parent_id : :unit_id} names no unit in the Org Graph"
  end

  def ensure_conversion_well_formed!
    return if params[:conversion].nil?

    pairs = params[:conversion].to_h.map { |held, becomes| [ held.to_s, becomes ] }
    if (bad = pairs.find { |held, becomes| !held.match?(UUID_RE) || !(becomes.is_a?(String) && becomes.match?(UUID_RE)) })
      raise Operations::Base::ParameterError, "conversion maps level ids to level ids, got #{bad.first.inspect} => #{bad.last.inspect}"
    end
    return unless (clash = pairs.group_by { it.first.downcase }.find { |_, given| given.map { it.last.downcase }.uniq.size > 1 })

    raise Operations::Base::ParameterError, "conversion gives #{clash.first} two different types"
  end

  def conversion_option
    return {} if params[:conversion].nil?

    @conversion_option ||= { conversion: params[:conversion].to_h.to_h { |held, becomes| [ held.to_s.downcase, becomes.to_s.downcase ] } }
  end
end
