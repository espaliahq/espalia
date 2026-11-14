# frozen_string_literal: true

ForgottenPersonAudit.walk("assessments_feedback_recipients") { { query: "former" } }
