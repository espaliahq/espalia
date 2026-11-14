# frozen_string_literal: true

ForgottenPersonAudit.walk("assessments_comments_list") { { **cell, evidence_id: @evidence_id } }
