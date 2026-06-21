# frozen_string_literal: true

# Updates a level's editorial details — title and/or short code. Shape-preserving
# (these don't renumber the rating grid), so it applies live regardless of draft
# state. The shape-changing ordinal move (`change_level_ordinal`) is a separate,
# draft-gated operation and is out of scope here.
#
# `is_entry` (the entry-level flag) is intentionally NOT exposed yet: it's a
# Boolean, and Operations::Base's parameter validation has no Boolean type that
# accepts both true and false (Ruby has no Boolean class). It lands with the
# follow-up that adds Boolean support + the structured-field editors.
#
# Org-structure edits are direct (not the suggested-edit path that capability /
# category text uses): gated by FrameworkPolicy#update_level? — the edit-rights
# bar (owner / editor / leads or tenant admin).
#
# Write — :mcp_client.
class Operations::Frameworks::UpdateLevel < Operations::Base
  description "Update a level's title or code (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :level_id,     String, required: true
  parameter :title,        String
  parameter :code,         String

  def policy_check
    authorize framework, :update_level?
  end

  # @return [Hash] { framework_id:, level_id:, title: }
  def perform
    require_update_field!

    Frameworks::CommandHandler.new.update_level_details(
      framework.framework_id, params[:level_id],
      title: params[:title].presence, code: params[:code].presence
    )
    { framework_id: framework.framework_id, level_id: params[:level_id], title: params[:title] }
  end

  private

  def require_update_field!
    return if [ params[:title], params[:code] ].any?(&:present?)

    raise Operations::Base::ParameterError, "provide a title or code to update"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
