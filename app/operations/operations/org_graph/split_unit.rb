# frozen_string_literal: true

# Splits a unit into new units beside it: each placed member moves to their
# successor, anyone unplaced is left in no team, and the unit retires.
class Operations::OrgGraph::SplitUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite

  PLACEMENTS_SCHEMA = {
    type: "object",
    additionalProperties: { type: "string" },
    description: "person_id => the name of the successor they move to, one of successor_names. Members left " \
                 "out end their membership and show as in no team."
  }.freeze

  description "Split a unit into two or more new units from effective_on (today by default). The successors " \
              "take the unit's level and parent. Each person placements names moves to their successor with " \
              "the same role and allocation; anyone not named leaves and shows as in no team. The unit " \
              "retires, and everything shares one cause. A unit with live sub-units, or one an HRIS " \
              "supplies, is refused."
  approval :in_app

  parameter :unit_id, String, required: true
  parameter :successor_names, Array, required: true,
            schema: { type: "array", items: { type: "string" }, minItems: 2,
                      description: "names of the new units, at least two, each different" }
  parameter :placements, Hash, schema: PLACEMENTS_SCHEMA

  # @return [Hash] `{ unit_id, successors: [{ unit_id, name }], placed, unplaced, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    held_by_espalia!(unit)
    without_live_children!(unit)
    successors = successor_names.index_with { SecureRandom.uuid_v7 }
    placements = placements_by_unit(unit, successors)
    unplaced = active_memberships(unit).pluck(:person_id) - placements.keys

    split(unit, successors, placements)
    { unit_id: unit.id, successors: successors.map { |name, id| { unit_id: id, name: name } },
      placed: placements.size, unplaced: unplaced.sort, effective_on: effective_on }
  rescue ArgumentError => e # the aggregate's guards, such as a member who moved out meanwhile
    raise Operations::Base::ParameterError, e.message
  end

  private

  def successor_names
    names = Array(params[:successor_names]).map { |name| name.to_s.strip }
    raise Operations::Base::ParameterError, "Name at least two successors" if names.size < 2
    raise Operations::Base::ParameterError, "Every successor needs a name" if names.any?(&:empty?)
    raise Operations::Base::ParameterError, "Each successor needs its own name" unless names.uniq(&:downcase).size == names.size

    names
  end

  # @return [Hash{String => String}] person id => successor unit id
  def placements_by_unit(unit, successors)
    members = unit.memberships.pluck(:person_id)
    (params[:placements] || {}).to_h.each_with_object({}) do |(person_id, name), placed|
      person_id = person_id.to_s.downcase
      raise Operations::Base::ParameterError, "#{person_id} is not in #{unit.name}" unless members.include?(person_id)

      placed[person_id] = successors.fetch(name.to_s.strip) do
        raise Operations::Base::ParameterError, "#{name.inspect} is not one of the successors"
      end
    end
  end

  def split(unit, successors, placements)
    handler = structure_handler(cause_id: SecureRandom.uuid_v7)
    ActiveRecord::Base.transaction do
      successors.each do |name, id|
        handler.create_unit(id, name, level_id: unit.level_id, parent_id: unit.parent_id, effective_on: effective_on)
      end
      handler.apply_succession(SecureRandom.uuid_v7, predecessor_ids: [ unit.id ], successor_ids: successors.values,
                                                     effective_on: effective_on, placements: placements)
    end
  end
end
