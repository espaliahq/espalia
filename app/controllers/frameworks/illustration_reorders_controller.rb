# frozen_string_literal: true

# Moves one illustration before/after a sibling in its expectation × role
# list, from the explorer's edit-mode ↑/↓ chevrons. The chevrons post a
# neighbour-relative move (the visible list IS the complete list for that
# role, so the DOM neighbour is always a real sibling); this controller
# translates it into the complete ordering the shared
# {Operations::Frameworks::ReorderIllustrations} takes, so web and MCP share
# one implementation.
#
# Responds 204 — the reorder-list Stimulus controller moves the DOM node
# itself (a full matrix refresh would collapse the expanded row), and the
# activity feed updates via the usual broadcast.
class Frameworks::IllustrationReordersController < ApplicationController
  before_action :set_framework

  # POST /frameworks/:framework_id/illustration_reorders
  def create
    authorize @framework, :reorder_illustrations?

    Operations::Frameworks::ReorderIllustrations.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        expectation_id: illustration.expectation_id,
        role_id: illustration.role_id,
        new_ordering: new_ordering
      }
    )

    head :no_content
  rescue Operations::Base::ParameterError, RuntimeError, ActiveRecord::RecordNotFound
    # A stale neighbour (concurrent edit) or cross-framework id — the client
    # leaves the DOM untouched on a non-2xx, so the list stays consistent.
    head :unprocessable_content
  end

  private

  def reorder_params
    @reorder_params ||= params.expect(reorder: [ :illustration_id, :target_id, :placement ])
  end

  # Scoped to the authorized framework via role → role_family — a smuggled
  # cross-framework id 404s here (mcp-server.md Lesson 5).
  def illustration
    @illustration ||= FrameworkState::RoleIllustration
      .joins(role: :role_family)
      .where(framework_role_families: { framework_id: @framework.framework_id })
      .find_by!(illustration_id: reorder_params[:illustration_id])
  end

  # Current display order for the illustration's (expectation, role), with the
  # moving id re-inserted before/after the target neighbour.
  def new_ordering
    ids = FrameworkState::RoleIllustration
      .where(expectation_id: illustration.expectation_id, role_id: illustration.role_id)
      .order(:ordinal, :id)
      .pluck(:illustration_id)

    moving = illustration.illustration_id
    target = reorder_params[:target_id].to_s
    raise ActiveRecord::RecordNotFound, "target #{target} not in this list" unless ids.include?(target)

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
