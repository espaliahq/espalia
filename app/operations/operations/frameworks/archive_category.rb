# frozen_string_literal: true

# Archives a capability category. Unlike a capability, a category carries no
# ratings, so there is NO migration mapping to record — archiving is a plain
# structural retirement. The aggregate refuses if the category still holds any
# active capabilities (archive those first, each via ArchiveCapability), so the
# realistic flow is: empty the category, then archive it.
#
# Archiving auto-opens a draft if none is open (shape-changing — see
# Frameworks::Aggregate#ensure_draft_in_progress!); the live impact lands at
# publish.
#
# Write — :mcp_client. It stages a structural change into the open draft; the
# version cut (publish) is :in_app. Restricted to edit-rights holders
# (FrameworkPolicy#archive_category?).
class Operations::Frameworks::ArchiveCategory < Operations::Base
  description "Archive an (empty) capability category (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :category_id,  String, required: true
  parameter :reason,       String

  def policy_check
    authorize framework, :archive_category?
  end

  # @return [Hash] { framework_id:, category_id:, name: }
  def perform
    Frameworks::CommandHandler.new.archive_capability_category(
      framework.framework_id, category.category_id, reason: params[:reason]
    )

    { framework_id: framework.framework_id, category_id: category.category_id, name: category.name }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (NOT the published read model) so a category
  # added in the current draft can still be archived. The graph is
  # per-framework, so finding the id in it scopes the lookup to the authorized
  # framework.
  def category
    @category ||= explorer_graph.capability_categories
      .find { |c| c.category_id == params[:category_id] } ||
      raise(ActiveRecord::RecordNotFound, "category #{params[:category_id]} not found in this framework")
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
