# frozen_string_literal: true

# One calendar month within an assessment cycle's lifespan — the reporting
# period a cycle report can be narrowed to. Months are keyed `YYYY-MM`, the
# wire format shared by the web `month` param and the MCP parameter, and are
# bounded in the application time zone.
#
# @example
#   Reporting::CycleMonth.available_for(cycle).map(&:key) # => ["2026-03", "2026-02", "2026-01"]
#   Reporting::CycleMonth.find_in(cycle, "2026-02").range # => Feb 1 00:00 .. Feb 28 23:59:59
class Reporting::CycleMonth
  KEY_FORMAT = /\A\d{4}-(0[1-9]|1[0-2])\z/
  # The same rule as KEY_FORMAT in JSON Schema syntax, advertised on the MCP tool.
  JSON_SCHEMA_PATTERN = "^[0-9]{4}-(0[1-9]|1[0-2])$"

  attr_reader :start

  # Every month the cycle has spanned so far, most recent first. An open cycle
  # runs through the current month; a closed one stops at its close.
  #
  # @param cycle [AssessmentCycle]
  # @return [Array<Reporting::CycleMonth>]
  def self.available_for(cycle)
    first = cycle.opened_at.in_time_zone.beginning_of_month
    last = (cycle.closed_at || Time.current).in_time_zone.beginning_of_month
    months = []
    month = first
    while month <= last
      months << new(month)
      month = month.next_month
    end
    months.reverse
  end

  # @param cycle [AssessmentCycle]
  # @param key [String, nil] a `YYYY-MM` month key
  # @return [Reporting::CycleMonth, nil] the month when it lies within the cycle
  def self.find_in(cycle, key)
    return nil if key.blank?

    available_for(cycle).find { |month| month.key == key }
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
    start.all_month
  end

  def ==(other)
    other.is_a?(self.class) && key == other.key
  end
  alias eql? ==

  def hash
    key.hash
  end
end
