# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_plan_members") { { plan_id: @plan_id } }
