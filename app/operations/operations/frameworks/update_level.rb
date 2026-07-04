# frozen_string_literal: true

# Updates a level's editorial details — title, short code, and/or the
# entry-level flag. Shape-preserving (these don't renumber the rating grid), so
# it applies live regardless of draft state. The shape-changing ordinal move
# (`change_level_ordinal`) is a separate, draft-gated operation and is out of
# scope here.
#
# Org-structure edits are direct (not the suggested-edit path that capability /
# category text uses): gated by FrameworkPolicy#update_level? — the edit-rights
# bar (owner / editor / leads or tenant admin).
#
# Write — :mcp_client.
class Operations::Frameworks::UpdateLevel < Operations::Base
  description "Update a level's title, code, or entry-level flag (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :level_id,     String, required: true
  parameter :title,        String
  parameter :code,         String
  parameter :is_entry,     :boolean

  def policy_check
    authorize framework, :update_level?
  end

  # @return [Hash] { framework_id:, level_id:, title: }
  def perform
    require_update_field!

    Frameworks::CommandHandler.new.update_level_details(
      framework.framework_id, params[:level_id],
      title: params[:title].presence, code: params[:code].presence, is_entry: params[:is_entry]
    )
    { framework_id: framework.framework_id, level_id: params[:level_id], title: params[:title] }
  end

  private

  # A supplied is_entry — true OR false — counts as an update (nil means "not
  # supplied"; the aggregate compacts nils away).
  def require_update_field!
    return if [ params[:title], params[:code] ].any?(&:present?) || !params[:is_entry].nil?

    raise Operations::Base::ParameterError, "provide a title, code, or is_entry to update"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
