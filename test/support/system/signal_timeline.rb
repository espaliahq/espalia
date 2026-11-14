# frozen_string_literal: true

# What a guarded click saw, in order: its own steps from Ruby, and from the
# page when the signal text came and went and when Turbo submitted and
# rendered. A failed click reports it, so a flake that won't reproduce
# locally can be read from the CI log (#241).
class SignalTimeline
  # @return [Integer] Ruby's wall clock in ms
  def self.now = (Time.now.to_f * 1000).round

  # @param read_page_events [#call] returns the page's [ms, event] pairs, nil
  #   after a full page load, or :unavailable when the page could not be read
  # @param page_offset [Numeric, nil] Ruby's clock minus the page's, measured
  #   when the timeline was armed; nil when it could not be measured
  # @param clock [#call] returns the time in ms
  def initialize(read_page_events, page_offset: nil, clock: SignalTimeline.method(:now))
    @read_page_events = read_page_events
    @page_offset = page_offset
    @clock = clock
    @marks = []
  end

  # @param what [String]
  def mark(what)
    @marks << [ @clock.call, what ]
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
    lines = if @page_offset
              ordered(@marks + page_marks(page_events))
    else
              ordered(@marks) + [ "  page events, on the page's own clock:" ] + ordered(page_marks(page_events))
    end
    lines << "  (no page events: the page fully reloaded after the click)" if page_events.nil?
    lines << "  (no page events: the page could not be read)" if page_events == :unavailable
    "signal timeline (#{@page_offset ? 'page times on the test clock' : 'clocks not aligned'}):\n#{lines.join("\n")}"
  end

  private

  # Ties keep the order each side recorded them in; sort_by alone is unstable.
  def ordered(events)
    start = events.map(&:first).min
    events.each_with_index.sort_by { |(at, _), i| [ at, i ] }.map { |(at, what), _| format("  %+7dms %s", at - start, what) }
  end

  def page_marks(page_events)
    return [] unless page_events.is_a?(Array)

    page_events.map { |at, what| [ (at + @page_offset.to_f).round, what ] }
  end
end
