# frozen_string_literal: true

# Names a run the machine was paused during. A paused VM stops the monotonic
# clock and has its wall clock corrected when it wakes, so the lead the wall
# clock gains is the time spent paused.
class PausedRun
  # Large enough that a routine correction of the wall clock stays quiet.
  THRESHOLD_SECONDS = 10

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

  # @return [String, nil] what to tell whoever reads the run, or nil when the clocks kept together
  def notice
    paused = seconds_paused
    return if paused < THRESHOLD_SECONDS

    <<~NOTICE

      The wall clock gained #{duration(paused)} on the monotonic clock during this run, as it does
      when the machine is paused: a host that sleeps freezes the devcontainer's VM. Browser calls
      in flight when it wakes can fail together, in several workers in the same second, with
      "Timeout when executing request" or a stale element. If this run has failures like that,
      rerun it. What fails again is real; what passes may still be an intermittent defect
      (docs/guidelines/dev-environment.md).
    NOTICE
  end

  # Prints the notice, if there is one.
  #
  # @param io [IO]
  # @return [void]
  def report(io = $stdout)
    notice&.then { |text| io.puts text }
  end

  private

  def duration(seconds)
    return "#{seconds.round} seconds" if seconds < 90

    "about #{(seconds / 60.0).round} minutes (#{seconds.round}s)"
  end
end
