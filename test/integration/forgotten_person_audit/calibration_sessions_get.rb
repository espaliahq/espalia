# frozen_string_literal: true

ForgottenPersonAudit.walk("calibration_sessions_get") { { session_id: @session_id } }
