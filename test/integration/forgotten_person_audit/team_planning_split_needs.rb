# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_split_needs") { { plan_id: @plan_id, scenario_id: @scenario_id } }
