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
# Responds 204 — the reorder-move Stimulus controller dispatches
# `org-structure:updated` → matrix#refresh (a capability is a compact row
# plus its hidden expanded row, so no DOM surgery).
class Frameworks::CapabilityReordersController < ApplicationController
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

    head :no_content
  rescue Operations::Base::ParameterError, RuntimeError, ActiveRecord::RecordNotFound
    head :unprocessable_content
  end

  private

  def reorder_params
    @reorder_params ||= params.expect(reorder: [ :capability_id, :target_id, :placement ])
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
    index = ids.index(target) + (reorder_params[:placement] == "after" ? 1 : 0)
    ids.insert(index, moving)
    ids
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
