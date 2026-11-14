# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_status") { { plan_id: @plan_id, scenario_id: @plan_id } }
