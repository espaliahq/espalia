# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_scenario_costs") { { plan_id: @plan_id } }
