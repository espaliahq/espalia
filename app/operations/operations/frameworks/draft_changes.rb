# frozen_string_literal: true

# What publishing the open draft would change: capabilities and categories
# added or archived, roles a capability gains or loses, levels and
# expectations added — each with the open-cycle people it reaches where that
# applies. The publish-review page renders it; an MCP agent reads it before
# asking for `frameworks_publish_version`, which it can't otherwise see.
class Operations::Frameworks::DraftChanges < Operations::Base
  description "What publishing the open draft would change (capabilities, categories, role " \
              "bindings, levels, expectations) and how many open-cycle people each change reaches."
  category :read
  approval :none

  parameter :framework_id, String, required: true

  def policy_check
    authorize framework, :edit?
  end

  # @return [Hash] { framework_id:, draft_version:, changes: { kind => [..] } }
  #   `draft_version` is nil and every list empty when no draft is open
  def perform
    changes = if framework.draft?
      Frameworks::DraftChangesQuery.new(framework).call
    else
      Frameworks::DraftChangesQuery::KINDS.index_with { [] }
    end

    { framework_id: framework.framework_id, draft_version: framework.draft_version, changes: changes }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
