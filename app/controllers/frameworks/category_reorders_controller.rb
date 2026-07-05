# frozen_string_literal: true

# Moves one capability category before/after a sibling, from the explorer's
# edit-mode category-header ↑/↓ chevrons. The chevrons post a
# neighbour-relative move against the categories the viewer can SEE (role /
# search filters can hide some), and this controller re-inserts the moving
# category next to that visible neighbour within the full active order before
# dispatching the shared {Operations::Frameworks::ReorderCategories}.
#
# Responds 204 — the reorder-move Stimulus controller dispatches
# `org-structure:updated`, which the explorer layout routes to matrix#refresh,
# so the acting user re-renders in the new order (feed updates via broadcast).
class Frameworks::CategoryReordersController < ApplicationController
  before_action :set_framework

  # POST /frameworks/:framework_id/category_reorders
  def create
    authorize @framework, :reorder_categories?

    Operations::Frameworks::ReorderCategories.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, new_ordering: new_ordering }
    )

    head :no_content
  rescue Operations::Base::ParameterError, RuntimeError, ActiveRecord::RecordNotFound
    head :unprocessable_content
  end

  private

  def reorder_params
    @reorder_params ||= params.expect(reorder: [ :category_id, :target_id, :placement ])
  end

  # Current display order of the active categories, with the moving id
  # re-inserted before/after the target neighbour.
  def new_ordering
    ids = FrameworkState::CapabilityCategory
      .where(framework_id: @framework.framework_id, status: "active")
      .order(:ordinal, :id)
      .pluck(:category_id)

    moving = reorder_params[:category_id].to_s
    target = reorder_params[:target_id].to_s
    unless ids.include?(moving) && ids.include?(target) && moving != target
      raise ActiveRecord::RecordNotFound, "category or target not in this framework"
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
