# frozen_string_literal: true

# Moves one capability before/after a sibling in its category, from the
# explorer's edit-mode row-actions kebab. The kebab posts a neighbour-relative
# move against the rows the viewer can SEE (role / search filters hide some;
# struck pending-archive rows aren't movable), and this controller re-inserts
# the moving capability next to that neighbour within the category's full
# reorderable order — resolved from the ExplorerGraph so draft-added
# capabilities are first-class (framework-explorer.md Lesson 17) — before
# dispatching the shared {Operations::Frameworks::ReorderCapabilities}.
#
# Answers the toast Turbo Stream only — `reorder-move` repositions the
# capability's compact + expanded rows in place. It used to answer 204 and
# dispatch `org-structure:updated` → matrix#refresh, re-fetching ~950 KB of
# edit-mode matrix (and every loaded expanded row with it) to change the order
# of two rows.
class Frameworks::CapabilityReordersController < ApplicationController
  include Frameworks::SuggestionAuthority
  include Frameworks::WriteResponse

  before_action :set_framework

  # POST /frameworks/:framework_id/capability_reorders
  def create
    authorize @framework, :reorder_capabilities?

    Operations::Frameworks::ReorderCapabilities.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        category_id: category.category_id,
        new_ordering: new_ordering
      }
    )

    render_write_streams([ toast_stream("Moved “#{moving_capability_name}”.") ])
  rescue Operations::Base::ParameterError, RuntimeError, ActiveRecord::RecordNotFound => e
    render_write_error(e.message)
  end

  private

  def reorder_params
    @reorder_params ||= params.expect(reorder: [ :capability_id, :target_id, :placement ])
  end

  # Named in the toast so a mis-click is obvious. Resolved from the graph, which
  # includes draft-added capabilities (Hard-Won Lesson 17).
  def moving_capability_name
    category.capabilities.find { |c| c.capability_id == reorder_params[:capability_id] }&.name
  end

  def graph
    @graph ||= Frameworks::ExplorerGraph.load(@framework.framework_id)
  end

  # The category owning the moving capability, resolved from the graph (per-
  # framework, includes draft-added entities).
  def category
    @category ||= graph.capability_categories.find do |cat|
      cat.capabilities.any? { |c| c.capability_id == reorder_params[:capability_id] }
    end || raise(ActiveRecord::RecordNotFound, "capability not found in this framework")
  end

  # The category's reorderable capabilities in display order (graph order),
  # with the moving id re-inserted before/after the target neighbour.
  def new_ordering
    ids = category.capabilities
      .reject { |c| c.status != "active" || (c.respond_to?(:pending_archive) && c.pending_archive) }
      .map(&:capability_id)

    moving = reorder_params[:capability_id].to_s
    target = reorder_params[:target_id].to_s
    unless ids.include?(moving) && ids.include?(target) && moving != target
      raise ActiveRecord::RecordNotFound, "capability or target not reorderable in this category"
    end

    ids.delete(moving)
    ids.insert(ids.index(target) + placement_offset, moving)
    ids
  end

  # Fail a malformed placement fast (422) instead of silently treating any
  # non-"after" value as "before".
  def placement_offset
    case reorder_params[:placement]
    when "before" then 0
    when "after" then 1
    else raise Operations::Base::ParameterError, "placement must be before or after"
    end
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
