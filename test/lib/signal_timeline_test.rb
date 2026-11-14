# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/system/signal_timeline")

class SignalTimelineTest < ActiveSupport::TestCase
  should "put page events on the test clock and keep each side's order on a tie" do
    page_events = [ [ 900, "signal added in <div>" ], [ 900, "signal removed with <div>" ] ]
    timeline = SignalTimeline.new(-> { page_events }, page_offset: 100)
    timeline.instance_variable_set(:@marks, [ [ 990, "click" ], [ 1000, "probe 1 started" ] ])

    assert_equal <<~REPORT.chomp, timeline.report
      signal timeline (page times on the test clock):
             +0ms click
            +10ms probe 1 started
            +10ms signal added in <div>
            +10ms signal removed with <div>
    REPORT
  end

  should "say so when the page lost its events" do
    timeline = SignalTimeline.new(-> { nil })
    timeline.mark("click")

    assert_match(/the page fully reloaded after the click/, timeline.report)
  end
end
