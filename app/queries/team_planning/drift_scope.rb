# frozen_string_literal: true

# Cuts a scoped plan's drift to the people and units it covers
# ([#435](https://github.com/espaliahq/espalia/issues/435)). A scope hides
# the organisation's data about anything outside it, so a change about
# someone or some unit the plan never covered is dropped, names and all.
#
# Covered means held by the baseline or by any scenario's map, plus whoever
# and whatever the window itself brings into a covered unit. A change that
# takes a covered person or unit out keeps saying so, but not where to: the
# destination is data about something outside. The same for a covered
# person now reporting to someone the plan can't name. Each cut field is
# listed in `outside`.
class TeamPlanning::DriftScope
  PERSON_KINDS = %i[joined left fact_changed].freeze
  MEMBERSHIP_KINDS = %i[membership_started membership_ended membership_changed moved].freeze
  UNIT_KINDS = %i[unit_created unit_renamed unit_moved unit_retired owner_added owner_removed].freeze

  # @!attribute change [OrgGraph::ChangesBetween::Change] with outside fields cut
  # @!attribute outside [Array<String>] the fields cut: "unit_id", "from_unit_id", "before", "after" or "person_id"
  Cut = Data.define(:change, :outside)

  # @param maps [Array<TeamPlanning::Baseline::Map>] the baseline's and each scenario's
  def initialize(maps)
    @people = maps.flat_map { |map| map.people.map(&:id) + map.departed.map(&:person_id) }.to_set
    @nameable = maps.flat_map(&:person_ids).to_set | @people
    @units = maps.flat_map { it.known_unit_ids.to_a }.to_set
  end

  # @param changes [Array<OrgGraph::ChangesBetween::Change>]
  # @return [Array<Cut>] the changes the plan covers, in the order given
  def call(changes)
    widen(changes)
    changes.filter_map { cut(it) }
  end

  private

  # A unit created or moved under a covered one, and a person placed in a
  # covered unit, are covered from then on, so their other changes show.
  def widen(changes)
    loop do
      before = [ @people.size, @units.size ]
      changes.each do |change|
        case change.kind
        when :unit_created, :unit_moved then @units << change.unit_id if @units.include?(change.after&.dig("parent_id"))
        when :membership_started, :membership_changed, :moved then @people << change.person_id if @units.include?(change.unit_id)
        end
      end
      @nameable |= @people
      break if before == [ @people.size, @units.size ]
    end
  end

  def cut(change)
    case change.kind
    when *PERSON_KINDS then person(change)
    when *MEMBERSHIP_KINDS then membership(change)
    when *UNIT_KINDS then unit(change)
    when :unit_succeeded then succession(change)
    end
  end

  def person(change)
    return unless @people.include?(change.person_id)
    return Cut.new(change:, outside: []) unless change.fact == "manager"

    fields = %w[before after].select { (id = change.public_send(it)&.dig("manager_id")) && !@nameable.include?(id) }
    Cut.new(change: change.with(**fields.to_h { [ it.to_sym, change.public_send(it).merge("manager_id" => nil) ] }), outside: fields)
  end

  def membership(change)
    return unless @people.include?(change.person_id)

    fields = %w[unit_id from_unit_id].select { (id = change.public_send(it)) && !@units.include?(id) }
    return if fields.include?("unit_id") && (change.kind != :moved || fields.include?("from_unit_id"))

    Cut.new(change: change.with(**fields.to_h { [ it.to_sym, nil ] }), outside: fields)
  end

  def unit(change)
    return unless @units.include?(change.unit_id)

    case change.kind
    when :unit_moved
      fields = %w[before after].select { (id = change.public_send(it)&.dig("parent_id")) && !@units.include?(id) }
      Cut.new(change: change.with(**fields.to_h { [ it.to_sym, change.public_send(it).merge("parent_id" => nil) ] }), outside: fields)
    when :unit_retired
      after = change.after&.merge("successor_ids" => Array(change.after["successor_ids"]).select { @units.include?(it) })
      Cut.new(change: change.with(after:), outside: after == change.after ? [] : [ "after" ])
    when :owner_added, :owner_removed
      @nameable.include?(change.person_id) ? Cut.new(change:, outside: []) : Cut.new(change: change.with(person_id: nil), outside: [ "person_id" ])
    else Cut.new(change:, outside: [])
    end
  end

  def succession(change)
    ids = %w[before after].flat_map { |side| %w[predecessor_ids successor_ids].flat_map { Array(change.public_send(side)&.dig(it)) } }
    return unless ids.any? { @units.include?(it) }

    cuts = %w[before after].filter_map do |side|
      fields = change.public_send(side)
      next unless fields

      kept = fields.to_h { |key, value| [ key, key.end_with?("_ids") ? Array(value).select { @units.include?(it) } : value ] }
      [ side, kept ] unless kept == fields
    end
    Cut.new(change: change.with(**cuts.to_h { [ it.first.to_sym, it.last ] }), outside: cuts.map(&:first))
  end
end
