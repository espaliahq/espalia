# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_rule") { { plan_id: @plan_id, scenario_id: @scenario_id, rule: "on_cost" } }
