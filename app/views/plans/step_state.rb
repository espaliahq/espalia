# frozen_string_literal: true

# One badge for where a scenario's step stands
# ([#466](https://github.com/espaliahq/espalia/issues/466)), as the Scenarios
# table and the timeline show it. A closed step also says when, and who closed it.
class Views::Plans::StepState < Views::Base
  BADGES = {
    "baseline" => [ "Read only", :neutral ],
    "open" => [ "Draft", :info ],
    "ready_to_close" => [ "Ready to close", :brand ],
    "closed" => [ "Closed", :success ],
    "not_taken" => [ "Not taken", :neutral ]
  }.freeze

  # @param scenario [Hash] from `team_planning_scenarios`
  def initialize(scenario)
    @scenario = scenario
  end

  def view_template
    key = @scenario[:parent_id].nil? ? "baseline" : @scenario[:state]
    label, tone = BADGES.fetch(key, BADGES["open"])
    span(class: "inline-flex flex-wrap items-baseline gap-x-2", data: { step_state: key }) do
      render Components::Kit::Badge.new(label, tone:)
      span(class: "text-xs text-muted") { closed_line } if key == "closed" && @scenario[:closed_on]
    end
  end

  private

  def closed_line
    on = Date.iso8601(@scenario[:closed_on]).strftime("%-d %b")
    by = @scenario.dig(:closed_by, :name)
    by ? "on #{on} by #{by}" : "on #{on}"
  end
end
