# frozen_string_literal: true

# Names a run the machine was paused during. A paused VM stops the monotonic
# clock and has its wall clock corrected when it wakes, so the lead the wall
# clock gains is the time spent paused.
class PausedRun
  THRESHOLD_SECONDS = 30

  # @param wall [#call] seconds on the wall clock
  # @param monotonic [#call] seconds on the monotonic clock
  def initialize(wall: -> { Process.clock_gettime(Process::CLOCK_REALTIME) },
                 monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @wall = wall
    @monotonic = monotonic
    @wall_start = wall.call
    @monotonic_start = monotonic.call
  end

  # @return [Float] seconds the wall clock has gained on the monotonic clock since the run began
  def seconds_paused
    (@wall.call - @wall_start) - (@monotonic.call - @monotonic_start)
  end

  # @return [String, nil] what to tell whoever reads the run, or nil when it was not paused
  def notice
    paused = seconds_paused
    return if paused < THRESHOLD_SECONDS

    <<~NOTICE

      This machine was paused for about #{duration(paused)} during the run: the wall clock gained
      #{paused.round}s on the monotonic clock. A host that sleeps does this. Browser calls in
      flight when it woke fail together, with "Timeout when executing request" or a stale
      element. Rerun before reading those as test failures (docs/guidelines/dev-environment.md).
    NOTICE
  end

  private

  def duration(seconds)
    return "#{seconds.round} seconds" if seconds < 90

    "#{(seconds / 60).round} minutes"
  end
end
