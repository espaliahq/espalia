# frozen_string_literal: true

# What changed in the Org Graph between two days, read from {OrgFactPeriod}
# as typed {Change}s a caller can group and count.
#
# By effective date (the default), the changes that took effect after `from`,
# up to and including `to`: the steps from `OrgGraph::AsOf` on `from` to
# `OrgGraph::AsOf` on `to`. It reads what the Org Graph knows now, or with
# `known_on` what it knew at the end of that day.
#
# By learned date, what the Org Graph learned after the end of `from`, up to
# the end of `to` (UTC), whatever day each change took effect. A backdated
# correction shows here with its earlier date. A change it no longer
# believes, such as one changed back on its own day, comes back `withdrawn`.
#
# A change takes effect on the first day it holds, so a leaving dated 30
# April is a `left` on 1 May, the first day the person is off the roster.
#
# Everyone is named by id, as in `OrgGraph::AsOf`. A unit's name is the
# exception: the structure events carry it.
#
# @example
#   result = OrgGraph::ChangesBetween.new(context:, from: Date.new(2026, 1, 1), to: Date.new(2026, 3, 31)).call
#   result.changes.count { it.kind == :joined }
#   result.changes.select { it.kind == :moved }.group_by(&:unit_id)
class OrgGraph::ChangesBetween
  BY = %i[effective learned].freeze

  KINDS = %i[
    joined left fact_changed
    membership_started membership_ended membership_changed moved
    unit_created unit_renamed unit_moved unit_retired unit_succeeded
    owner_added owner_removed
  ].freeze

  # The changes between two days.
  #
  # @!attribute from [Date]
  # @!attribute to [Date]
  # @!attribute by [Symbol] :effective or :learned
  # @!attribute known_on [Date, nil] for :effective, nil for what is known now
  # @!attribute changes [Array<Change>] in effective date order
  Result = Data.define(:from, :to, :by, :known_on, :changes)

  # One change.
  #
  # @!attribute kind [Symbol] one of {KINDS}
  # @!attribute effective_on [Date] the first day it holds
  # @!attribute learned_at [Time] when the Org Graph learned it, or for a
  #   withdrawn change when it stopped believing it
  # @!attribute person_id [String, nil] the person, or for an owner change the owner
  # @!attribute unit_id [String, nil] the unit; for a move, the unit joined
  # @!attribute from_unit_id [String, nil] for a move, the unit left
  # @!attribute succession_id [String, nil] for a succession
  # @!attribute fact [String, nil] for `fact_changed`: "title", "level",
  #   "manager", "cost_centre", "site" or "employment"
  # @!attribute before [Hash, nil] the fact's fields before, nil when new
  # @!attribute after [Hash, nil] the fact's fields after, nil when it ended
  # @!attribute provider [String, nil] who supplied it
  # @!attribute event_id [String] the event that wrote it
  # @!attribute withdrawn [Boolean] by learned date only: true when the Org
  #   Graph no longer believes a change it had learned before the window
  Change = Data.define(:kind, :effective_on, :learned_at, :person_id, :unit_id, :from_unit_id, :succession_id,
                       :fact, :before, :after, :provider, :event_id, :withdrawn)

  PERSON = OrgGraph::Projections::History::PERSON
  UNIT = OrgGraph::Projections::History::UNIT
  SUCCESSION = OrgGraph::Projections::History::SUCCESSION
  private_constant :PERSON, :UNIT, :SUCCESSION

  # A fact's value stepping from `before` to `after` on `on`.
  Step = Data.define(:subject_type, :subject_id, :fact, :key, :on, :before, :after, :provider, :event_id, :learned_at)
  private_constant :Step

  # @param context [AuthorizationContext]
  # @param from [Date] the day before the window opens
  # @param to [Date] the window's last day
  # @param by [Symbol] :effective or :learned
  # @param known_on [Date, nil] by effective date only: read what was known
  #   at the end of this day
  # @raise [ArgumentError] for an unknown `by`, a `to` before `from`, or a
  #   `known_on` by learned date
  def initialize(context:, from:, to:, by: :effective, known_on: nil)
    raise ArgumentError, "by must be one of #{BY.join(", ")}" unless BY.include?(by)
    raise ArgumentError, "to must not be before from" if to < from
    raise ArgumentError, "known_on reads by effective date only" if known_on && by == :learned

    @context = context
    @from = from
    @to = to
    @by = by
    @known_on = known_on
  end

  # @return [Result]
  # @raise [Pundit::NotAuthorizedError] when the caller can't see the Org Graph
  def call
    Pundit.authorize(@context, :org_graph, :show?)

    changes = @by == :effective ? effective_changes : learned_changes
    Result.new(from: @from, to: @to, by: @by, known_on: @known_on, changes: sorted(changes))
  end

  private

  # ── By effective date ──

  def effective_changes
    window = (@from + 1)..@to
    rows = facts(OrgFactPeriod.known_on(@known_on))
    rows = rows.where(effective_from: window).or(rows.where(effective_to: window))
    changes_from(steps(rows.to_a).select { window.cover?(it.on) }, withdrawn: false)
  end

  # ── By learned date ──

  # Compares each timeline the window touched as known at its start and its
  # end. A step only the end knows was learned; one only the start knew was
  # withdrawn.
  def learned_changes
    opened, closed = [ @from, @to ].map { it.in_time_zone("UTC").end_of_day }
    touched = facts(OrgFactPeriod.where(learned_at: opened..closed).or(OrgFactPeriod.where(superseded_at: opened..closed)))
              .distinct.pluck(:subject_type, :subject_id, :fact, :key)
    return [] if touched.empty?

    before = timeline_steps(touched, OrgFactPeriod.known_on(@from)).index_by { identity(it) }
    after = timeline_steps(touched, OrgFactPeriod.known_on(@to)).index_by { identity(it) }
    learned = after.except(*before.keys).values
    withdrawn = before.except(*after.keys).values.map { it.with(learned_at: superseded_at(it, closed)) }
    changes_from(learned, withdrawn: false) + changes_from(withdrawn, withdrawn: true)
  end

  def timeline_steps(touched, knowledge)
    timelines = touched.map { |type, id, fact, key| knowledge.where(subject_type: type, subject_id: id, fact:, key:) }
    steps(timelines.reduce(:or).to_a)
  end

  # A step is the same step at both ends however its row was rewritten since,
  # so the time it was learned is no part of it.
  def identity(step) = step.to_h.except(:learned_at)

  # When the Org Graph stopped believing a step it held at the window's start.
  def superseded_at(step, closed)
    OrgFactPeriod.where(subject_type: step.subject_type, subject_id: step.subject_id, fact: step.fact, key: step.key,
                        event_id: step.event_id, effective_from: step.on, superseded_at: ..closed)
                 .maximum(:superseded_at)
  end

  # ── Steps ──

  def facts(scope)
    scope.where(subject_type: PERSON, fact: OrgGraph::AsOf::PERSON_FACTS + %w[membership])
         .or(scope.where(subject_type: UNIT, fact: OrgGraph::AsOf::UNIT_FACTS))
         .or(scope.where(subject_type: SUCCESSION, fact: "succession"))
  end

  # Each row begins a step from the value of the row that ends the day it
  # starts, or from nothing.
  def steps(rows)
    rows.group_by { [ it.subject_type, it.subject_id, it.fact, it.key ] }.flat_map do |(type, id, fact, key), timeline|
      ending = timeline.index_by(&:effective_to)
      timeline.filter_map do |row|
        before = ending[row.effective_from]&.value
        next if before == row.value

        Step.new(subject_type: type, subject_id: id, fact:, key:, on: row.effective_from, before:, after: row.value,
                 provider: row.provider, event_id: row.event_id, learned_at: row.learned_at)
      end
    end
  end

  # ── Kinds ──

  def changes_from(steps, withdrawn:)
    steps = fold_moves(steps)
    steps = fold_unit_creation(steps)
    steps.filter_map { |step| step.is_a?(Change) ? step.with(withdrawn:) : change(step, withdrawn:) }
  end

  # A move ends one membership and starts another in one event.
  def fold_moves(steps)
    memberships = steps.select { it.fact == "membership" }
    moves = memberships.group_by { [ it.subject_id, it.event_id, it.on ] }.filter_map do |_, pair|
      left = pair.select { it.after.nil? }
      joined = pair.select { it.before.nil? }
      next unless pair.size == 2 && left.one? && joined.one?

      [ pair, build(:moved, joined.first, person_id: joined.first.subject_id, unit_id: joined.first.key,
                                          from_unit_id: left.first.key, before: left.first.before, after: joined.first.after) ]
    end
    steps - moves.flat_map(&:first) + moves.map(&:last)
  end

  # Creating a unit writes its name, parent, level and status in one event.
  def fold_unit_creation(steps)
    created = steps.select { it.is_a?(Step) && it.subject_type == UNIT && it.fact == "status" && it.before.nil? }
    created.flat_map do |status|
      parts = steps.select do
        it.is_a?(Step) && it.subject_type == UNIT && it.subject_id == status.subject_id && it.event_id == status.event_id &&
          it.before.nil? && it.on == status.on
      end
      after = parts.reject { it.fact == "status" }.map(&:after).compact.reduce({}, :merge)
      steps = steps - parts + [ build(:unit_created, status, unit_id: status.subject_id, before: nil, after:) ]
    end
    steps
  end

  def change(step, withdrawn:)
    case step.subject_type
    when PERSON then person_change(step)
    when UNIT then unit_change(step)
    when SUCCESSION then build(:unit_succeeded, step, succession_id: step.subject_id)
    end&.with(withdrawn:)
  end

  def person_change(step)
    person = { person_id: step.subject_id }
    case step.fact
    when "employment_status" then employment_change(step, person)
    when "membership"
      kind = if step.before.nil? then :membership_started
      elsif step.after.nil? then :membership_ended
      else :membership_changed
      end
      build(kind, step, **person, unit_id: step.key)
    else build(:fact_changed, step, **person, fact: step.fact)
    end
  end

  # Employed is on the roster; pending and left are not.
  def employment_change(step, person)
    employed = ->(value) { value&.fetch("employment_status", nil) == "employed" }
    if employed.(step.after) then build(:joined, step, **person)
    elsif employed.(step.before) then build(:left, step, **person)
    end
  end

  def unit_change(step)
    unit = { unit_id: step.subject_id }
    case step.fact
    when "name" then build(:unit_renamed, step, **unit)
    when "parent" then build(:unit_moved, step, **unit)
    when "status" then build(:unit_retired, step, **unit) if step.after&.fetch("status", nil) == "retired"
    when "owner" then build(step.after ? :owner_added : :owner_removed, step, **unit, person_id: step.key, before: nil, after: nil)
    end
  end

  def build(kind, step, **fields)
    Change.new(kind:, effective_on: step.on, learned_at: step.learned_at, person_id: nil, unit_id: nil,
               from_unit_id: nil, succession_id: nil, fact: nil, before: step.before, after: step.after,
               provider: step.provider, event_id: step.event_id, withdrawn: false, **fields)
  end

  def sorted(changes)
    changes.sort_by { [ it.effective_on, KINDS.index(it.kind), it.unit_id.to_s, it.person_id.to_s, it.withdrawn ? 1 : 0 ] }
  end
end
