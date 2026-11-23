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
    notice = run_with(wall: [ 1_000, 2_778 ], monotonic: [ 50, 1_164 ]).notice

    assert_includes notice, "paused for about 11 minutes"
    assert_includes notice, "gained\n664s"
    assert_includes notice, "docs/guidelines/dev-environment.md"
  end

  should "give a short pause in seconds" do
    assert_includes run_with(wall: [ 0, 145 ], monotonic: [ 0, 100 ]).notice, "paused for about 45 seconds"
  end

  should "say nothing about a gap a clock correction could explain" do
    assert_nil run_with(wall: [ 0, 129 ], monotonic: [ 0, 100 ]).notice
  end

  should "say nothing when the wall clock was set back" do
    assert_nil run_with(wall: [ 1_000, 900 ], monotonic: [ 0, 100 ]).notice
  end
end
