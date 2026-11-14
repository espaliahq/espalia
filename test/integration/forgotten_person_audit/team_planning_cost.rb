# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_cost") { { plan_id: @plan_id, scenario_id: @scenario_id, unit_id: @unit_id } }
