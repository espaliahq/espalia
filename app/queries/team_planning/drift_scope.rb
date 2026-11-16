# frozen_string_literal: true

# Cuts a scoped plan's drift to the people and units it covers
# ([#435](https://github.com/espaliahq/espalia/issues/435)). A scope hides
# the organisation's data about anything outside it, so a change about
# someone or some unit the plan doesn't cover at that point is dropped,
# names and all.
#
# Coverage follows the window in date order. Someone the baseline covers
# stops counting from the change that takes them out of the plan's units,
# and counts again if they come back. Someone the window brings in counts
# from that change on. Anyone a scenario holds that the baseline doesn't,
# and the plan's own units, count throughout, since the plan placed them.
#
# The change that takes someone or some unit out says so, but not where to,
# and the change that brings them in doesn't say where from: the other end
# is data about something outside. The same for a covered person now
# reporting to someone the plan can't name, and for the value a fact held
# before a change if it was set while they were outside, before the window
# or in it. Each cut field is listed in `outside`.
#
# Within a day, units move first, then joiners take their places, then people
# move, and only then are joiners and facts judged. So a title that changes on
# the day someone leaves goes with them, and a joiner's same-day moves and
# manager are judged with everyone in place. A move the Org Graph knew before
# the window that takes effect after the base moves them too, on its own day,
# though the window never reports it, unless the window withdraws it.
#
# A change that took effect before the base, learned since, drops `before`:
# coverage is judged from the base on, so the earlier value may have been set
# while its subject was outside.
#
# A unit is named only if the plan covers it at the window's end: today's name
# of one that has left may have been set while it was outside.
class TeamPlanning::DriftScope
  PERSON_KINDS = %i[joined left fact_changed].freeze
  MEMBERSHIP_KINDS = %i[membership_started membership_ended membership_changed moved].freeze
  UNIT_KINDS = %i[unit_created unit_renamed unit_moved unit_retired owner_added owner_removed].freeze
  ENTERING = %i[membership_started moved].freeze
  ADVANCING = %i[joined membership_started membership_ended moved unit_created unit_moved].freeze
  NOTED = %i[fact_changed unit_renamed].freeze
  PENDING = (ADVANCING + NOTED).to_set.freeze
  RANK = { unit_created: 0, unit_moved: 0, unit_succeeded: 0, joined: 1,
           membership_started: 2, membership_ended: 2, membership_changed: 2, moved: 2 }.freeze

  # @!attribute change [OrgGraph::ChangesBetween::Change] with outside fields cut
  # @!attribute outside [Array<String>] the fields cut: "unit_id", "from_unit_id", "before", "after" or "person_id"
  Cut = Data.define(:change, :outside)

  # @param base [TeamPlanning::Baseline::Map] the plan's baseline
  # @param maps [Array<TeamPlanning::Baseline::Map>] each scenario's, the root's included
  # @param parents [Hash{String => String, nil}] every unit's parent on the base day, outside ones included
  def initialize(base, maps, parents: {})
    @base_on = base.base_on
    based = held_people(base)
    @pinned = maps.flat_map { held_people(it).to_a }.to_set - based
    @unplaced = base.people.select { it.memberships.none?(&:unit_id) }.to_set(&:id)
    @placed = (base.people + base.outside).to_h { [ it.id, it.memberships.filter_map(&:unit_id).to_set ] }
    @named = [ base, *maps ].flat_map(&:person_ids).to_set - based
    @roots = Set.new(base.scope_ids) | (maps.flat_map { it.known_unit_ids.to_a }.to_set - base.known_unit_ids)
    @parents = parents.merge([ base, *maps ].flat_map { it.units + it.retired_units }.to_h { [ it.id, it.parent_id ] })
    @shown = based | @pinned | base.known_unit_ids | @roots
    @unseen = Set.new
    @known = Set.new
  end

  # @param changes [Array<OrgGraph::ChangesBetween::Change>] in date order
  # @param known [Array<OrgGraph::ChangesBetween::Change>] changes known before the window that take effect after
  #   the base: each moves the window on, or is noted, on its own day, and is never reported. A move counts ahead of
  #   that day's changes; a fact or name is noted after its moves, as the window's own are judged
  # @return [Array<Cut>] the changes the plan covers when they happen, in the order given
  def call(changes, known: [])
    withdrawn = changes.select(&:withdrawn).to_set { identity(it) }
    pending = known.select { PENDING.include?(it.kind) && !withdrawn.include?(identity(it)) }
                   .sort_by { [ it.effective_on, RANK.fetch(it.kind, 3) ] }
    cuts = Array.new(changes.size)
    changes.each_with_index.group_by { |change, _| change.effective_on }.each_value do |day|
      known_until(pending, day.first.first.effective_on)
      units, joiners, moves, facts = day.group_by { |change, _| RANK.fetch(change.kind, 3) }.values_at(0, 1, 2, 3).map(&:to_a)
      units.each { |change, index| cuts[index] = judge(change) }
      joiners.each { |change, _| advance(change) unless change.withdrawn }
      moves.each { |change, index| cuts[index] = judge(change) }
      known_until(pending, day.first.first.effective_on, facts: true)
      joiners.each { |change, index| cuts[index] = cut(change) }
      facts.each { |change, index| cuts[index] = judge(change) }
    end
    cuts.compact.map { backdated(it) }
  end

  # @param unit_id [String]
  # @return [Boolean] whether the plan covers the unit once {#call} has walked the window
  def covers_unit?(unit_id) = covered_unit?(unit_id)

  private

  def backdated(cut)
    return cut unless cut.change.effective_on < @base_on && !cut.change.before.nil?

    Cut.new(change: cut.change.with(before: nil), outside: cut.outside | [ "before" ])
  end

  def held_people(map) = map.people.to_set(&:id) | map.departed.to_set(&:person_id)

  def judge(change) = cut(change).tap { advance(change) unless change.withdrawn }

  # One Org Graph event writes several facts, so a withdrawal names its change
  # by more than the event.
  def identity(change) = [ change.event_id, change.kind, change.person_id, change.unit_id, change.fact ]

  # A move known before the window counts from its own day, unreported. A
  # joiner or unit it creates inside the plan is shown from then on; someone it
  # moves in keeps what was set while they were outside unseen. A known fact or
  # name on a day the window has changes waits for that day's moves.
  def known_until(pending, day, facts: false)
    while (change = pending.first) && (change.effective_on < day || (change.effective_on == day && (facts || !NOTED.include?(change.kind))))
      pending.shift
      next note(change) if NOTED.include?(change.kind)

      advance(change)
      @shown << change.person_id if change.kind == :joined && covered?(change.person_id)
      @shown << change.unit_id if change.kind == :unit_created && covered_unit?(change.unit_id)
    end
  end

  # A known fact or name about a subject outside the plan that day stays unseen;
  # one about a subject it covers is known.
  def note(change)
    subject_id, inside = change.kind == :unit_renamed ? [ change.unit_id, covered_unit?(change.unit_id) ] : [ change.person_id, covered?(change.person_id) ]
    key = marker(change, subject_id)
    return @unseen << key unless inside

    @unseen.delete(key)
    @known << key
  end

  def covered?(person_id)
    @pinned.include?(person_id) || @unplaced.include?(person_id) || Array(@placed[person_id]).any? { covered_unit?(it) }
  end

  # Someone the baseline holds is nameable only while the plan covers them;
  # anyone else a plan's map names stays nameable.
  def nameable?(person_id) = @named.include?(person_id) || covered?(person_id)

  def covered_unit?(unit_id)
    seen = Set.new
    while unit_id && seen.add?(unit_id)
      return true if @roots.include?(unit_id)

      unit_id = @parents[unit_id]
    end
    false
  end

  # Moves the window on past a change, so the next is judged as it happens.
  def advance(change)
    case change.kind
    when :joined then place(change.person_id) { Set.new(change.after&.dig("memberships")&.keys) }
    when :membership_started then place(change.person_id) { it << change.unit_id }
    when :membership_ended then place(change.person_id) { it.delete(change.unit_id) }
    when :moved then place(change.person_id) { it.delete(change.from_unit_id) << change.unit_id }
    when :unit_created, :unit_moved then @parents[change.unit_id] = change.after&.dig("parent_id")
    end
  end

  # Someone the plan covers who loses their last place stays, as unassigned,
  # just as the baseline keeps them.
  def place(person_id)
    was = covered?(person_id)
    @unplaced.delete(person_id)
    @placed[person_id] = yield(@placed.fetch(person_id, Set.new).dup).delete(nil)
    @unplaced << person_id if was && @placed[person_id].empty?
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
    return unseen(change, change.person_id) unless covered?(change.person_id) || joins_covered?(change)
    return joined(change) if change.kind == :joined

    cut = seen?(change, change.person_id) ? { before: nil } : {}
    if change.fact == "manager"
      %i[before after].each do |side|
        next if cut.key?(side)

        id = change.public_send(side)&.dig("manager_id")
        cut[side] = change.public_send(side).merge("manager_id" => nil) if id && !nameable?(id)
      end
    end
    Cut.new(change: change.with(**cut), outside: %w[before after] & cut.keys.map(&:to_s))
  end

  # A fact or name set while its subject was outside the plan, before the
  # window or during it, is data about something outside, so the next change
  # to it once covered drops it as `before`.
  def unseen(change, subject_id)
    @unseen << marker(change, subject_id) unless change.withdrawn
    nil
  end

  def seen?(change, subject_id)
    key = marker(change, subject_id)
    outside = @unseen.include?(key) || !(@shown.include?(subject_id) || @known.include?(key))
    unless change.withdrawn
      @unseen.delete(key)
      @known << key
    end
    outside && !change.before.nil?
  end

  # A joiner's facts arrive whole, so whatever names a unit or someone outside
  # the plan goes, and the rest stays.
  def joined(change)
    after = change.after.to_h
    kept = after.merge({ "memberships" => after["memberships"]&.select { |unit_id, _| covered_unit?(unit_id) },
                         "owned_unit_ids" => after["owned_unit_ids"]&.select { covered_unit?(it) },
                         "manager_id" => (after["manager_id"] if nameable?(after["manager_id"])) }.slice(*after.keys))
    @shown << change.person_id unless change.withdrawn
    kept == after ? Cut.new(change:, outside: []) : Cut.new(change: change.with(after: kept), outside: [ "after" ])
  end

  def shown(change, subject_id)
    @shown << subject_id unless change.withdrawn
    Cut.new(change:, outside: [])
  end

  def marker(change, subject_id) = [ subject_id, change.kind, change.fact ]

  def joins_covered?(change)
    change.kind == :joined && Array(change.after&.dig("memberships")&.keys).any? { covered_unit?(it) }
  end

  def membership(change)
    return unless covered?(change.person_id) || (ENTERING.include?(change.kind) && covered_unit?(change.unit_id))

    fields = %w[unit_id from_unit_id].select { (id = change.public_send(it)) && !covered_unit?(id) }
    return if fields.include?("unit_id") && (change.kind != :moved || fields.include?("from_unit_id"))

    Cut.new(change: change.with(**fields.to_h { [ it.to_sym, nil ] }), outside: fields)
  end

  def unit(change)
    entering = %i[unit_created unit_moved].include?(change.kind) && covered_unit?(change.after&.dig("parent_id"))
    return unseen(change, change.unit_id) unless covered_unit?(change.unit_id) || entering

    return shown(change, change.unit_id) if change.kind == :unit_created

    case change.kind
    when :unit_renamed
      seen?(change, change.unit_id) ? Cut.new(change: change.with(before: nil), outside: [ "before" ]) : Cut.new(change:, outside: [])
    when :unit_moved
      fields = %w[before after].select { (id = change.public_send(it)&.dig("parent_id")) && !covered_unit?(id) }
      Cut.new(change: change.with(**fields.to_h { [ it.to_sym, change.public_send(it).merge("parent_id" => nil) ] }), outside: fields)
    when :unit_retired
      after = change.after&.merge("successor_ids" => Array(change.after["successor_ids"]).select { covered_unit?(it) })
      Cut.new(change: change.with(after:), outside: after == change.after ? [] : [ "after" ])
    when :owner_added, :owner_removed
      nameable?(change.person_id) ? Cut.new(change:, outside: []) : Cut.new(change: change.with(person_id: nil), outside: [ "person_id" ])
    else Cut.new(change:, outside: [])
    end
  end

  def succession(change)
    ids = %w[before after].flat_map { |side| %w[predecessor_ids successor_ids].flat_map { Array(change.public_send(side)&.dig(it)) } }
    return unless ids.any? { covered_unit?(it) }

    cuts = %w[before after].filter_map do |side|
      fields = change.public_send(side)
      next unless fields

      kept = fields.to_h { |key, value| [ key, key.end_with?("_ids") ? Array(value).select { covered_unit?(it) } : value ] }
      [ side, kept ] unless kept == fields
    end
    Cut.new(change: change.with(**cuts.to_h { [ it.first.to_sym, it.last ] }), outside: cuts.map(&:first))
  end
end
