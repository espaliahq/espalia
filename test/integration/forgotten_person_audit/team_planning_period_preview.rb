# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_period_preview") do
  { plan_id: @plan_id, scenario_id: @scenario_id, ends_on: (Date.current + 60).iso8601 }
end
