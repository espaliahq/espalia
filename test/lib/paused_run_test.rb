# frozen_string_literal: true

require "test_helper"

class PausedRunTest < ActiveSupport::TestCase
  def run_with(wall:, monotonic:)
    PausedRun.new(wall: -> { wall.shift }, monotonic: -> { monotonic.shift })
  end

  should "say nothing when both clocks ran together" do
    assert_nil run_with(wall: [ 1_000, 2_114 ], monotonic: [ 50, 1_164 ]).notice
  end

  should "name the pause when the wall clock gained on the monotonic clock" do
    notice = run_with(wall: [ 1_000.0, 2_778.2 ], monotonic: [ 50.0, 1_164.0 ]).notice

    assert_match(/gained about 11 minutes \(664s\) on the monotonic clock/, notice)
    assert_includes notice, "docs/guidelines/dev-environment.md"
  end

  should "round a pause to the nearest minute, whatever the clocks count in" do
    assert_match(/about 2 minutes \(119s\)/, run_with(wall: [ 0, 219 ], monotonic: [ 0, 100 ]).notice)
  end

  should "give a short pause in seconds" do
    assert_match(/gained 45 seconds on/, run_with(wall: [ 0, 145 ], monotonic: [ 0, 100 ]).notice)
  end

  should "say nothing about a gap shorter than a Capybara wait" do
    assert_nil run_with(wall: [ 0, 109 ], monotonic: [ 0, 100 ]).notice
  end

  should "say nothing when the wall clock was set back" do
    assert_nil run_with(wall: [ 1_000, 900 ], monotonic: [ 0, 100 ]).notice
  end

  should "print the notice once, and nothing for a run that kept time" do
    paused = StringIO.new
    run_with(wall: [ 0, 145 ], monotonic: [ 0, 100 ]).report(paused)
    quiet = StringIO.new
    run_with(wall: [ 0, 100 ], monotonic: [ 0, 100 ]).report(quiet)

    assert_equal 1, paused.string.scan("gained 45 seconds").size
    assert_empty quiet.string
  end
end
