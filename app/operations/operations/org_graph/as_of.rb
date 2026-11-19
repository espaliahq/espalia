# frozen_string_literal: true

# The Org Graph as it stood on one day, read through {OrgGraph::AsOf}: the
# live units, who was employed and who belonged where. People come back as
# ids only; callers join names.
#
# Incremental disclosure: defaults to `summary` (units with member counts). Pass
# `mode: "full"` for each person's facts and every membership, and `unit_id`
# to narrow either mode to one unit and the units under it.
#
# The read behind [#123](https://github.com/espaliahq/espalia/issues/123).
class Operations::OrgGraph::AsOf < Operations::Base
  include Operations::OrgGraph::DateParameter

  description "Read the Org Graph as it stood on one date: the live units with their parent, " \
              "level, owners and direct member count, the organisation's unit types with the type ids each " \
              "could sit under (parent_ids) and whether it could sit at the top, the same for each unit " \
              "that had a structure of its own (structures, by unit_id and its name that day), and the number of employed people. A future " \
              "date includes changes already recorded for it, such as a hire who starts then or a " \
              "scheduled move. known_on reads what the Org Graph knew at the end of that earlier " \
              "date in the tenant's time zone, leaving out corrections learned " \
              "since. mode \"full\" adds each employed " \
              "person's facts (title, level, manager, site, employment) and every membership. " \
              "unit_id narrows to that unit and the units under it, counting only the people " \
              "placed there. People are named by id only."
  category :read
  approval :none

  parameter :date, String, required: true, allow_blank: false,
    schema: DATE_SCHEMA.merge(description: "Date, YYYY-MM-DD.")
  parameter :known_on, String, required: false, allow_blank: false,
    schema: DATE_SCHEMA.merge(description: "Date, YYYY-MM-DD. Omit for what is known now.")
  parameter :mode, String, required: false, allowed: %w[summary full]
  parameter :unit_id, String, required: false, allow_blank: false, schema: { format: "uuid" }

  # @raise [Pundit::NotAuthorizedError] when the caller isn't a member of the tenant
  def policy_check
    authorize :org_graph, :show?
  end

  # @return [Hash] `:date`, `:known_on`, `:kinds` (the top structure's unit
  #   types on that date, top first, with their rules), `:structures` (each
  #   structure in force among the units reported, with its `:unit_id` and
  #   `:kinds`), `:people_count` (everyone employed,
  #   or with `unit_id` everyone placed under it) and `:units`, each with
  #   `:id`, `:name`, `:parent_id`, `:level_id`, `:owner_ids` and
  #   `:member_count` (its direct members); in full mode also `:people` and
  #   `:memberships`
  # @raise [Operations::Base::ParameterError] for a malformed date, or a
  #   unit_id that names no unit live on that date
  def perform
    snapshot = ::OrgGraph::AsOf.new(context:, date: parse_date(:date), known_on: parse_date(:known_on)).call
    unit_ids = within(snapshot.units)
    memberships = snapshot.memberships.select { unit_ids.include?(it.unit_id) }
    person_ids = memberships.to_set(&:person_id) if params[:unit_id].present?
    people = person_ids ? snapshot.people.select { person_ids.include?(it.id) } : snapshot.people

    payload(snapshot, snapshot.units.select { unit_ids.include?(it.id) }, people, memberships)
  end

  private

  def payload(snapshot, units, people, memberships)
    member_counts = memberships.group_by(&:unit_id).transform_values { it.map(&:person_id).uniq.size }
    result = {
      date: snapshot.date.iso8601,
      known_on: snapshot.known_on&.iso8601,
      people_count: people.size,
      kinds: kind_rows(snapshot.kinds),
      structures: structures_payload(snapshot, units),
      units: units.map { it.to_h.merge(member_count: member_counts.fetch(it.id, 0)) }
    }
    return result unless params[:mode] == "full"

    result.merge(people: people.map(&:to_h), memberships: memberships.map(&:to_h))
  end

  def structures_payload(snapshot, units)
    names = snapshot.units.to_h { [ it.id, it.name ] }
    structures_in_force(snapshot, units).map { |unit_id, kinds| { unit_id:, name: names[unit_id], kinds: kind_rows(kinds) } }
  end

  def kind_rows(kinds) = kinds.map { { id: it.id, name: it.name, provider: it.provider, **it.rules } }

  # @return [Hash{String => Array<OrgGraph::Taxonomy::Kind>}] the structures
  #   the reported units declare or sit in
  def structures_in_force(snapshot, units)
    return {} if snapshot.structures.empty?

    by_id = snapshot.units.index_by(&:id)
    in_force = units.flat_map do |unit|
      above = by_id[unit.parent_id]
      above = by_id[above.parent_id] until above.nil? || snapshot.structures.key?(above.id)
      [ unit.id, above&.id ]
    end
    snapshot.structures.slice(*in_force.compact)
  end

  # @return [Set<String>] the ids of the units to report on
  def within(units)
    return units.to_set(&:id) if params[:unit_id].blank?

    root = params[:unit_id].downcase
    raise ParameterError, "unit_id must name a unit live on #{params[:date]}" unless units.any? { it.id == root }

    children = units.group_by(&:parent_id)
    ids = Set.new
    queue = [ root ]
    while (id = queue.shift)
      next unless ids.add?(id)

      queue.concat(children.fetch(id, []).map(&:id))
    end
    ids
  end
end
