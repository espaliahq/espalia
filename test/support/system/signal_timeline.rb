# frozen_string_literal: true

# What a guarded click saw, in order: its own steps from Ruby, and from the
# page when the signal text came and went and when Turbo submitted and
# rendered. A failed click reports it, so a flake that won't reproduce
# locally can be read from the CI log (#241).
class SignalTimeline
  # @param read_page_events [#call] returns the page's events, nil after a
  #   full page load, or :unavailable when the page could not be read
  def initialize(read_page_events)
    @read_page_events = read_page_events
    @marks = []
  end

  # @param what [String]
  def mark(what)
    @marks << [ now, what ]
  end

  # Marks a probe's start and end around the block.
  #
  # @param number [Integer]
  # @return [Object] the block's value
  def probe(number)
    mark("probe #{number} started")
    landed = yield
    mark("probe #{number} ended, #{landed ? 'landed' : 'not landed'}")
    landed
  end

  # @return [String]
  def report
    page_events = @read_page_events.call
    events = @marks + (page_events.is_a?(Array) ? page_events : [])
    start = events.map(&:first).min
    lines = events.sort_by(&:first).map { |at, what| format("  %+7dms %s", at - start, what) }
    lines << "  (no page events: the page fully reloaded after the click)" if page_events.nil?
    lines << "  (no page events: the page could not be read)" if page_events == :unavailable
    "signal timeline (Ruby and browser clocks):\n#{lines.join("\n")}"
  end

  private

  def now = (Time.now.to_f * 1000).round
end
