# frozen_string_literal: true

ForgottenPersonAudit.walk("frameworks_capability_get") { { **framework, capability_id: @fx.shared.stable_id } }
