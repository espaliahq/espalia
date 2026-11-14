# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/system/signal_timeline")

class SignalTimelineTest < ActiveSupport::TestCase
  should "put page events on the test clock and keep each side's order on a tie" do
    page_events = [ [ 900, "signal added in <div>" ], [ 900, "signal removed with <div>" ] ]
    times = [ 990, 1000 ]
    timeline = SignalTimeline.new(-> { page_events }, page_offset: 100, clock: -> { times.shift })
    timeline.mark("click")
    timeline.mark("probe 1 started")

    assert_equal <<~REPORT.chomp, timeline.report
      signal timeline (page times on the test clock):
             +0ms click
            +10ms probe 1 started
            +10ms signal added in <div>
            +10ms signal removed with <div>
    REPORT
  end

  should "list page events apart, each side from its own start, when the clocks could not be aligned" do
    times = [ 990, 1000 ]
    timeline = SignalTimeline.new(-> { [ [ 5000, "signal added in <div>" ], [ 5030, "turbo:render" ] ] }, clock: -> { times.shift })
    timeline.mark("click")
    timeline.mark("probe 1 started")

    assert_equal <<~REPORT.chomp, timeline.report
      signal timeline (clocks not aligned):
             +0ms click
            +10ms probe 1 started
        page events, on the page's own clock:
             +0ms signal added in <div>
            +30ms turbo:render
    REPORT
  end

  should "say so when it watched for no signal" do
    assert_match(/signal not watched/, SignalTimeline.new(-> { [] }, watching: false).report)
    assert_no_match(/signal not watched/, SignalTimeline.new(-> { [] }).report)
  end

  should "say so when the page lost its events" do
    timeline = SignalTimeline.new(-> { nil })
    timeline.mark("click")

    assert_match(/the page fully reloaded after the click/, timeline.report)
  end
end
