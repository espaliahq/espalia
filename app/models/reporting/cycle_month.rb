# frozen_string_literal: true

# One calendar month within an assessment cycle's lifespan — the reporting
# period a cycle report can be narrowed to. Months are keyed `YYYY-MM`, the
# wire format shared by the web `month` param and the MCP parameter. Month
# boundaries follow `Time.zone` — UTC, as this app configures no zone and
# tenants carry none — so the payload's `starts_at` / `ends_at` are the
# authoritative statement of a month's window.
#
# @example
#   Reporting::CycleMonth.available_for(cycle).map(&:key) # => ["2026-03", "2026-02", "2026-01"]
#   Reporting::CycleMonth.find_in(cycle, "2026-02").range # => Feb 1 00:00 .. Feb 28 23:59:59
class Reporting::CycleMonth
  # One source for the key's shape: the Ruby check and the JSON Schema
  # `pattern` advertised on the MCP tool are both built from it, so they
  # can't drift.
  MONTH_PATTERN = "[0-9]{4}-(0[1-9]|1[0-2])"
  KEY_FORMAT = /\A#{MONTH_PATTERN}\z/
  JSON_SCHEMA_PATTERN = "^#{MONTH_PATTERN}$"

  # @return [ActiveSupport::TimeWithZone] the first instant of the month
  attr_reader :start

  # Every month the cycle's activity can fall in, most recent first. An open
  # cycle runs through the current month. A closed cycle runs through its
  # close — or later, when a response attributed to the cycle was recorded
  # after it closed (a late answer inherits its request's cycle), so every
  # month the whole-cycle counts draw from is selectable. Never empty: the
  # opening month is always offered, even under clock skew that puts "now"
  # before it.
  #
  # @param cycle [AssessmentCycle]
  # @return [Array<Reporting::CycleMonth>]
  def self.available_for(cycle)
    first = cycle.opened_at.in_time_zone.beginning_of_month
    last = [ cycle.closed_at || Time.current, latest_activity_at(cycle) ].compact
      .map { |time| time.in_time_zone.beginning_of_month }
      .push(first)
      .max
    months = []
    month = first
    while month <= last
      months << new(month)
      month = month.next_month
    end
    months.reverse
  end

  # The newest feedback or request timestamp explicitly attributed to the
  # cycle. Legacy rows carry no cycle id and are only ever inferred inside an
  # enrollment window, which the cycle's own span already covers.
  #
  # @param cycle [AssessmentCycle]
  # @return [Time, nil]
  def self.latest_activity_at(cycle)
    [
      EvidenceItem.where(cycle_id: cycle.cycle_id).maximum(:recorded_at),
      EvidenceRequest.where(cycle_id: cycle.cycle_id).maximum(:requested_at)
    ].compact.max
  end
  private_class_method :latest_activity_at

  # @param cycle [AssessmentCycle]
  # @param key [String, nil] a `YYYY-MM` month key
  # @param months [Array<Reporting::CycleMonth>, nil] an already-built
  #   `available_for(cycle)` list, for a caller that also renders it
  # @return [Reporting::CycleMonth, nil] the month when it lies within the cycle
  def self.find_in(cycle, key, months: nil)
    return nil if key.blank?

    (months || available_for(cycle)).find { |month| month.key == key }
  end

  # @param key [Object]
  # @return [Boolean] whether the value is shaped like a `YYYY-MM` key
  def self.valid_key?(key)
    key.is_a?(String) && KEY_FORMAT.match?(key)
  end

  # @param start [ActiveSupport::TimeWithZone] the first instant of the month
  def initialize(start)
    @start = start
  end

  # @return [String] `YYYY-MM`
  def key
    start.strftime("%Y-%m")
  end

  # @return [String] e.g. "June 2026"
  def label
    start.strftime("%B %Y")
  end

  # @return [Range<ActiveSupport::TimeWithZone>] the month's inclusive time span
  def range
    @range ||= start.all_month
  end
end
