# frozen_string_literal: true

ForgottenPersonAudit.walk("calibration_sessions_overview") { { session_id: @session_id } }
