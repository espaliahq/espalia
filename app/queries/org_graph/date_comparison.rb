# frozen_string_literal: true

# Compare with a date (#139): what the Units view marks for the changes
# {OrgGraph::ChangesBetween} finds between two days.
#
# By effective date, the window holds what took effect after `from`, up to
# and including `to`. By learned date, what the Org Graph learned after the
# end of `from` up to the end of `to`, in UTC; a change it stopped believing
# shows as withdrawn.
#
# Names come from {Person}, so a forgotten person reads "Former member".
class OrgGraph::DateComparison < OrgGraph::Comparison
  # The window a request asked for, checked.
  #
  # @!attribute from [Date] the date compared with
  # @!attribute to [Date] the window's last day
  # @!attribute by [Symbol] :effective or :learned
  Window = Data.define(:from, :to, :by) do
    # @return [Hash] the query parameters that ask for this window again
    def params = { from: from.iso8601, to: to.iso8601, by: by.to_s }
  end

  # A request's dates and mode could not make a window.
  class InvalidWindow < StandardError; end

  # @param from [String, nil] an ISO date
  # @param to [String, nil] an ISO date; today when blank
  # @param by [String, nil] "effective" or "learned"; effective when blank
  # @param today [Date]
  # @return [Window, nil] nil when no date was picked
  # @raise [InvalidWindow] with a message to show
  def self.window(from:, to:, by:, today: Date.current)
    return nil if from.blank?

    from_date = parse(from, "Pick a date to compare with.")
    to_date = to.present? ? parse(to, "Pick an end date, or leave it as today.") : today
    raise InvalidWindow, "Pick dates no later than today." if to_date > today
    raise InvalidWindow, "Pick an end date after the date you compare with." if to_date <= from_date

    mode = OrgGraph::ChangesBetween::BY.find { it.to_s == by.to_s } || :effective
    Window.new(from: from_date, to: to_date, by: mode)
  end

  def self.parse(value, message)
    Date.iso8601(value.to_s)
  rescue Date::Error, ArgumentError
    raise InvalidWindow, message
  end
  private_class_method :parse

  # @return [Window]
  attr_reader :window

  # @param context [AuthorizationContext]
  # @param window [Window]
  # @param today [Date]
  def initialize(context:, window:, today: Date.current)
    super()
    @window = window
    @today = today
    @changes = OrgGraph::ChangesBetween.new(context:, from: window.from, to: window.to, by: window.by).call.changes
  end

  def params = @window.params

  # @return [Boolean]
  def learned? = @window.by == :learned

  # @return [String] e.g. "Since 1 Oct" or "1 Oct to 5 Nov"
  def window_label
    @window.to == @today ? "Since #{day(@window.from)}" : "#{day(@window.from)} to #{day(@window.to)}"
  end

  COUNTED = {
    "Joined" => :joined, "Left" => :left, "Moved" => :moved,
    "New units" => :unit_created, "Renamed" => :unit_renamed, "Units moved" => :unit_moved,
    "Retired" => :unit_retired, "Succeeded" => :unit_succeeded
  }.freeze

  # @return [Array<Array(String, Integer)>] each kind of change the Org Graph
  #   still believes and how many, e.g. ["Joined", 3], then "Withdrawn" when any are
  def counts
    believed, withdrawn = @changes.select { COUNTED.value?(it.kind) }.partition { !it.withdrawn }
    counts = COUNTED.map { |label, kind| [ label, believed.count { it.kind == kind } ] }
    withdrawn.any? ? counts << [ "Withdrawn", withdrawn.size ] : counts
  end

  # @param unit [OrgUnit]
  # @return [Array<String>]
  def unit_marks(unit) = marks.fetch(unit.id, [])

  # @param unit [OrgUnit]
  # @return [Array<PersonChange>]
  def people_changes(unit) = people_by_unit.fetch(unit.id, [])

  # @param date [Date]
  # @return [String] e.g. "5 Nov", with the year when it isn't this year
  def day(date) = I18n.l(date, format: date.year == @today.year ? "%-d %b" : "%-d %b %Y")

  # A unit retired in the window, which today's tree no longer shows.
  Retirement = Data.define(:name, :last_day, :successors, :withdrawn)

  # @return [Array<Retirement>]
  def retirements
    @changes.select { it.kind == :unit_retired }.map do |change|
      Retirement.new(name: unit_name(change.unit_id), last_day: change.effective_on - 1,
                     successors: Array(change.after&.fetch("successor_ids", nil)).map { unit_name(it) },
                     withdrawn: change.withdrawn)
    end
  end

  private

  def marks
    @marks ||= @changes.group_by { it.unit_id || it.succession_id }.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(_, changes), result|
      unit_marks_from(changes).each { |unit_id, text| result[unit_id] << text }
    end
  end

  # A unit new in the window is "new" rather than renamed or moved: its first
  # name and parent are part of it. A succession it takes part in still shows.
  def unit_marks_from(changes)
    created = changes.find { it.kind == :unit_created }
    return [ [ created.unit_id, withdrawn("new", created) ] ] if created

    changes.filter_map do |change|
      case change.kind
      when :unit_renamed then [ change.unit_id, withdrawn("was #{change.before&.fetch("name", nil)}", change) ] if change.before
      when :unit_moved then [ change.unit_id, withdrawn(moved_from(change), change) ]
      end
    end + successions(changes)
  end

  def moved_from(change)
    parent_id = change.before&.fetch("parent_id", nil)
    parent_id ? "moved from #{unit_name(parent_id)}" : "moved"
  end

  def successions(changes)
    changes.select { it.kind == :unit_succeeded }.flat_map do |change|
      predecessors = Array(change.after&.fetch("predecessor_ids", nil)).map { unit_name(it) }.to_sentence
      Array(change.after&.fetch("successor_ids", nil)).map { [ it, withdrawn("succeeds #{predecessors}", change) ] }
    end
  end

  def people_by_unit
    @people_by_unit ||= @changes.flat_map { person_lines(it) }.group_by(&:first)
                                .transform_values { |lines| lines.map(&:last) }
  end

  def person_lines(change)
    case change.kind
    when :joined then joined_units(change).map { line(it, change, "joined #{when_of(change)}") }
    when :left then leaver_units(change).map { line(it, change, "left #{when_of(change, last_day: true)}") }
    when :moved
      [ line(change.unit_id, change, "moved in from #{unit_name(change.from_unit_id)} #{when_of(change)}"),
        line(change.from_unit_id, change, "moved to #{unit_name(change.unit_id)} #{when_of(change)}") ]
    when :membership_started
      joined_with?(change) ? [] : [ line(change.unit_id, change, "added #{when_of(change)}") ]
    when :membership_ended
      left_with?(change) ? [] : [ line(change.unit_id, change, "removed #{when_of(change, last_day: true)}") ]
    else []
    end
  end

  def line(unit_id, change, text)
    [ unit_id, PersonChange.new(name: person_name(change.person_id), text: withdrawn(text, change)) ]
  end

  def joined_units(change) = change.after&.fetch("memberships", {})&.keys || []

  # A joiner's first teams already show on their joining line.
  def joined_with?(change) = joinings.include?([ change.person_id, change.unit_id ])

  def joinings
    @joinings ||= @changes.select { it.kind == :joined }.flat_map { |change| joined_units(change).map { [ change.person_id, it ] } }.to_set
  end

  # A leaving ends the leaver's memberships the same day, and those show on the
  # leaving line. A leaving that ended none names the units the person is in today.
  def leaver_units(change)
    ended = ended_memberships.fetch([ change.person_id, change.effective_on ], [])
    return ended.map(&:unit_id).uniq if ended.any?

    @leaver_memberships ||= OrgMembership.where(person_id: @changes.select { it.kind == :left }.map(&:person_id))
                                         .pluck(:person_id, :unit_id).group_by(&:first)
    @leaver_memberships.fetch(change.person_id, []).map(&:last)
  end

  def ended_memberships
    @ended_memberships ||= @changes.select { it.kind == :membership_ended }.group_by { [ it.person_id, it.effective_on ] }
  end

  def left_with?(change) = leavings.include?([ change.person_id, change.effective_on ])

  def leavings
    @leavings ||= @changes.select { it.kind == :left }.to_set { [ it.person_id, it.effective_on ] }
  end

  # By learned date, a backdated change shows the day it took effect and the
  # day the Org Graph learned it.
  def when_of(change, last_day: false)
    took_effect = day(last_day ? change.effective_on - 1 : change.effective_on)
    return took_effect unless learned?

    "#{took_effect}, learned #{day(change.learned_at.to_date)}"
  end

  def withdrawn(text, change) = change.withdrawn ? "#{text} (withdrawn)" : text

  def person_name(id) = people.fetch(id, Person::FORMER_MEMBER)

  def people
    @people ||= Person.where(id: @changes.filter_map(&:person_id).uniq).pluck(:id, :name).to_h
  end

  def unit_name(id) = units.fetch(id, "an unknown unit")

  def units
    @units ||= begin
      ids = @changes.flat_map { [ it.unit_id, it.from_unit_id, *unit_ids_in(it.before), *unit_ids_in(it.after) ] }
      OrgUnit.where(id: ids.compact.uniq).pluck(:id, :name).to_h
    end
  end

  def unit_ids_in(value)
    return [] unless value.is_a?(Hash)

    value.values_at("parent_id", "predecessor_ids", "successor_ids").flatten.compact
  end
end
