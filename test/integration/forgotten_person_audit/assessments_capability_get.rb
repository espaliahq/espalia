# frozen_string_literal: true

ForgottenPersonAudit.walk("assessments_capability_get") { { **assessment, capability_id: @fx.shared.stable_id } }
