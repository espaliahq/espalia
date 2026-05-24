# frozen_string_literal: true

# Lists frameworks visible to the caller in the active tenant. Read-only,
# scoped automatically by acts_as_tenant + Pundit (FrameworkPolicy#index?
# = tenant_member?).
#
# Returns a flat array of hashes suitable for direct MCP serialization;
# we expose just the identity + version fields the MCP client typically
# needs to pick a framework before drilling in. Deeper data lives behind
# follow-up tools (e.g. a future `frameworks_get`).
class Operations::Frameworks::List < Operations::Base
  description "List frameworks visible to the caller in the active tenant."
  category :read
  approval :none

  def policy_check
    authorize FrameworkState::Framework, :index?
  end

  def perform
    FrameworkState::Framework.all.order(:name).map do |framework|
      {
        id: framework.framework_id,
        name: framework.name,
        current_published_version: framework.current_published_version,
        draft_in_progress: framework.draft_in_progress
      }
    end
  end
end
