# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_baseline") { { plan_id: @plan_id } }
