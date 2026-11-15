# frozen_string_literal: true

# Who a seat manages, read from the scenario's reporting lines
# ([#265](https://github.com/espaliahq/espalia/issues/265)). Units say nothing
# about who manages whom, with two exceptions for seats that have no line of
# their own:
#
# - An open position counts against the nearest unit, walking up from its
#   own, that holds exactly one other manager seat. Two or more in the
#   nearest unit that has any, or none up the tree, and it counts against
#   nobody, with a note saying so.
# - A vacant manager position also takes, as direct reports, the people that
#   walk leads to who have no manager on the map, so a seat whose lines
#   haven't been redrawn yet still carries its span. Someone who already
#   manages the seat, as the head of the tree does, is never its report, nor
#   is anyone who owns the seat's unit or a unit above it
#   ([#341](https://github.com/espaliahq/espalia/issues/341)).
#
# A leaver is never a report, and their reports, by name or by position,
# pass to the position backfilling them, or to nobody.
class TeamPlanning::CapacityModels::Units::Graph
  # @!attribute id [String] a person or a position
  # @!attribute kind [String] "person" or "position"
  # @!attribute distance [String] "direct", "skip" or "deeper"
  # @!attribute fte [Rational] 1 for a person, the open FTE for a position
  Report = Data.define(:id, :kind, :distance, :fte)

  DISTANCES = %w[direct skip deeper].freeze

  NOTES = {
    "unattributed_several_managers" => "The nearest unit with a manager seat has more than one, so this open seat counts against nobody",
    "unattributed_no_manager" => "No unit above this open seat has a manager seat, so it counts against nobody"
  }.freeze

  # @param map [TeamPlanning::Baseline::Map]
  # @param facts [TeamPlanning::CapacityModel::Facts]
  # @param manager_role_ids [Array<String>]
  def initialize(map:, facts:, manager_role_ids:)
    @map = map
    @open = facts.open_fte
    @role_ids_of = facts.role_ids_of
    @manager_role_ids = manager_role_ids.to_set
    @people = map.people.reject(&:leaving?).index_by(&:id)
    @units = map.units.index_by(&:id)
    @positions = map.positions.index_by(&:id)
    @lines = Hash.new { |hash, key| hash[key] = [] }
    @unmanaged = []
    route_lines
    @manager_ids = manager_ids
    @seats_in = seats_by_unit
    @notes = {}
    @attached = Hash.new { |hash, key| hash[key] = [] }
    attach_open_positions(manager: false)
    attach_open_positions(manager: true)
    attach_unmanaged
  end

  # @param id [String]
  # @return [Boolean]
  def manager?(id) = @manager_ids.include?(id)

  # Everyone the seat manages, nearest first, each once.
  #
  # @param id [String]
  # @return [Array<Report>]
  def span(id)
    seen = Set[id]
    reports = []
    frontier = [ id ]
    depth = 0
    until frontier.empty?
      distance = DISTANCES[[ depth, 2 ].min]
      frontier = frontier.flat_map { direct(it) }.uniq.select { seen.add?(it) }
      reports += frontier.map { report(it, distance) }
      depth += 1
    end
    reports
  end

  # @param id [String]
  # @return [Array<String>] keys for what a reader should know about the seat
  def notes_for(id) = @notes.fetch(id, [])

  private

  def direct(id) = (@lines[id] + @attached[id]).uniq

  def report(id, distance)
    position = !@people.key?(id)
    Report.new(id:, kind: position ? "position" : "person", distance:, fte: position ? @open.fetch(id, 0r) : 1r)
  end

  # A line to a leaver, or to a position only a leaver fills, passes to their
  # backfill; a line to anyone or any seat no longer on the map leaves the
  # person unmanaged.
  def route_lines
    @backfill_of = @map.backfills.flat_map { |position_id, ids| ids.map { [ it, position_id ] } }.to_h
    @occupants = @map.occupants
    @people.each_value do |person|
      target = manager_for(person)
      target ? @lines[target] << person.id : @unmanaged << person
    end
  end

  def manager_for(person)
    return seat_of(person.manager_position_id) unless person.manager_id
    return person.manager_id if @people.key?(person.manager_id)

    seat_of(@backfill_of[person.manager_id])
  end

  # A position manages through the one person in it, or as itself while
  # nobody is. Shared or closed, it manages nobody.
  def seat_of(position_id, seen = Set.new)
    return unless @positions.key?(position_id) && seen.add?(position_id)

    filled, leaving = @occupants.fetch(position_id, []).map(&:first).uniq(&:id).partition { !it.leaving? }
    return filled.first.id if filled.one?
    return unless filled.empty?

    backfills = leaving.filter_map { @backfill_of[it.id] }.uniq
    return seat_of(backfills.first, seen) if backfills.one?

    position_id if leaving.empty? && @open.key?(position_id)
  end

  def manager_ids
    seats = @people.keys + @open.keys
    seats.select { @lines[it].any? || @role_ids_of.fetch(it, []).any? { |role_id| @manager_role_ids.include?(role_id) } }.to_set
  end

  def seats_by_unit
    by_unit = Hash.new { |hash, key| hash[key] = [] }
    @manager_ids.each do |id|
      units = @people.key?(id) ? @people[id].memberships.map(&:unit_id) : [ @positions[id]&.unit_id ]
      units.compact.uniq.each { by_unit[it] << id }
    end
    by_unit
  end

  def attach_open_positions(manager:)
    @map.positions.each do |position|
      next if !@open.key?(position.id) || manager?(position.id) != manager

      above, note = nearest_manager(position.unit_id, except: position.id)
      next @notes[position.id] = [ note ] unless above
      next if manages?(position.id, above)

      @attached[above] << position.id
    end
  end

  def attach_unmanaged
    @unmanaged.each do |person|
      unit_id = TeamPlanning::Baseline::Membership.shares(person.memberships).min_by { |membership, share, _| [ -share, membership.unit_id.to_s ] }&.first&.unit_id
      manager, = nearest_manager(unit_id, except: person.id)
      next unless manager && !@people.key?(manager)
      next if manages?(person.id, manager) || owns_above?(person.id, @positions[manager]&.unit_id)

      @attached[manager] << person.id
    end
  end

  def owns_above?(person_id, unit_id)
    seen = Set.new
    while unit_id && seen.add?(unit_id)
      return true if @units[unit_id]&.owner_ids.to_a.include?(person_id)

      unit_id = @units[unit_id]&.parent_id
    end
    false
  end

  def manages?(id, other_id) = span(id).any? { it.id == other_id }

  def nearest_manager(unit_id, except:)
    seen = Set.new
    while unit_id && seen.add?(unit_id)
      seats = @seats_in.fetch(unit_id, []) - [ except ]
      return seats.one? ? [ seats.first, nil ] : [ nil, "unattributed_several_managers" ] if seats.any?

      unit_id = @units[unit_id]&.parent_id
    end
    [ nil, "unattributed_no_manager" ]
  end
end
