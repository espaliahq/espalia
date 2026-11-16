# frozen_string_literal: true

# A closed step's plan beside what happened, unit by unit
# ([#466](https://github.com/espaliahq/espalia/issues/466)). The planned side
# is the step as it closed, on the plan's own base. The actual side is the
# Org Graph on the step's last day, as it reads now, or as it read on the
# archive day once the plan is archived.
#
# Rows key on unit id, never on name: a unit renamed since matches by id, and
# one retired since keeps its plan name with nothing on the actual side.
#
# A person planned in a unit who isn't actually there reads as planned here
# but isn't, with no word on where they are: the Org Graph may hold them in a
# unit outside the plan's scope, or as having left, and neither may show.
#
# A seat reads as filled only where the plan itself links it to a person: an
# assignment of someone the Org Graph knows into that position, who is in its
# unit on the step's last day. Nobody new turning up in the unit fills it. A
# placeholder hire is the plan's own and never a person, so a seat it holds
# reads as not filled, and someone the plan didn't place reads as here but
# not planned. A placeholder hire reads as a hire not filled.
#
# Heads and names only: no levels, pay bands, cost or budget.
#
# @example
#   TeamPlanning::StepOutcome.new(context:, plan:, scenario_id: q1).call
class TeamPlanning::StepOutcome
  OUTCOMES = %w[as_planned planned_not_here here_not_planned hire_not_filled].freeze
  NOT_CLOSED = "This step isn't closed: close it to compare it with what happened"

  Outcome = Data.define(:ends_on, :known_on, :units, :names)
  Row = Data.define(:unit_id, :name, :planned_heads, :actual_heads, :people, :seats)
  PersonRow = Data.define(:person_id, :outcome)
  Seat = Data.define(:position_id, :filled_by_id, :hire_id)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String]
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [Outcome]
  # @raise [TeamPlanning::Error] {NOT_CLOSED} for a step that isn't closed, reopened ones included
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def call
    aggregate = @repository.load_plan(@plan.id)
    _, ends_on = aggregate.closed_steps.find { |id, _| id == @scenario_id }
    raise TeamPlanning::Error, NOT_CLOSED unless ends_on

    planned = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository).structure(aggregate)
    actual = TeamPlanning::Baseline.new(context: @context, plan: @plan).map_on(ends_on, known_on: @plan.archived_on)
    units = rows(planned, actual)
    Outcome.new(ends_on:, known_on: @plan.archived_on, units:, names: names(planned, units))
  end

  private

  def rows(planned, actual)
    planned_in = heads_by_unit(planned)
    actual_in = heads_by_unit(actual)
    seats = seats_by_unit(planned, actual_in)
    hires = planned.people.select(&:placeholder?).to_set(&:id)
    unit_names = actual.units.to_h { [ it.id, it.name ] }.merge(planned.units.to_h { [ it.id, it.name ] })

    unit_names.map do |unit_id, name|
      mine = planned_in.fetch(unit_id, {})
      theirs = actual_in.fetch(unit_id, {})
      Row.new(unit_id:, name:, planned_heads: heads(mine), actual_heads: heads(theirs),
              people: people(mine, theirs, hires), seats: seats.fetch(unit_id, []))
    end
  end

  # @return [Hash{String => Hash{String => Rational}}] unit id => person id => their share there
  def heads_by_unit(map)
    map.people.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0r) }) do |person, by_unit|
      map.counted_shares(person).each { |place, share, _| by_unit[place.unit_id][person.id] += share if place.unit_id }
    end
  end

  def heads(shares) = shares.values.sum(0r).round(2).to_f

  def people(planned, actual, hires)
    ids = (planned.keys + actual.keys).uniq
    ids.map do |id|
      outcome = if hires.include?(id) then "hire_not_filled"
      elsif planned.key?(id) && actual.key?(id) then "as_planned"
      elsif planned.key?(id) then "planned_not_here"
      else "here_not_planned"
      end
      PersonRow.new(person_id: id, outcome:)
    end
  end

  def seats_by_unit(planned, actual_in)
    occupants = planned.occupants
    planned.positions.select(&:unit_id).group_by(&:unit_id).transform_values do |positions|
      positions.map do |position|
        held = occupants.fetch(position.id, []).map(&:first)
        filled = held.reject(&:placeholder?).find { actual_in.fetch(position.unit_id, {}).key?(it.id) }
        Seat.new(position_id: position.id, filled_by_id: filled&.id, hire_id: (held.find(&:placeholder?)&.id unless filled))
      end
    end
  end

  def names(planned, units)
    ids = units.flat_map { |row| row.people.map(&:person_id) + row.seats.filter_map(&:filled_by_id) }.uniq
    hires = planned.people.select(&:placeholder?)
                  .to_h { [ it.id, it.placeholder.removed? ? TeamPlanning::Baseline::PLACEHOLDER_NAME : it.placeholder.reveal ] }
    known = ::Person.where(tenant_id: @plan.tenant_id, id: ids).pluck(:id, :name).to_h
    ids.to_h { [ it, hires[it] || known[it] || ::Person::FORMER_MEMBER ] }
       .merge(units.flat_map(&:seats).filter_map(&:hire_id).to_h { [ it, hires[it] ] })
  end
end
