# frozen_string_literal: true

ForgottenPersonAudit.walk("frameworks_suggestion_get") { { framework_id: @suggested_framework_id, suggestion_id: @suggestion_id } }
