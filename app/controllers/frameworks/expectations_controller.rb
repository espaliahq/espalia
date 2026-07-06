# frozen_string_literal: true

# Handles inline behavioural-expectation edits submitted from the Framework
# Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController}. Expectations expose only a
# `description` field — the level_ordinal/capability_id are grid-position
# and not directly edited.
#
class Frameworks::ExpectationsController < ApplicationController
  include FrameworkEditMode

  before_action :set_framework
  before_action :set_expectation, only: [ :update ]

  # POST /frameworks/:framework_id/expectations
  #
  # Authors a behavioural expectation in a previously-empty capability × level
  # cell via the matrix "+ Add expectation" affordance. Follows the suggest/
  # approve path (the Operation routes through suggest_create): applied directly
  # for an author with approval authority in editing mode, otherwise proposed as
  # a pending suggestion. Redirects back to the edit page.
  def create
    authorize @framework, :suggest_edit?
    attrs = params.expect(behavioural_expectation: [ :capability_id, :level_ordinal, :description ])
    # Fail fast on a malformed ordinal rather than silently coercing it to 0
    # (which would author at level 0).
    level_ordinal = Integer(attrs[:level_ordinal], exception: false)
    raise Operations::Base::ParameterError, "level must be a positive number" if level_ordinal.nil? || level_ordinal <= 0

    result = Operations::Frameworks::SetBehaviouralExpectation.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        capability_id: attrs[:capability_id],
        level_ordinal: level_ordinal,
        description: attrs[:description].to_s,
        mode: framework_edit_mode.to_s
      }
    )
    notice =
      if result[:amended] then "Updated your proposed expectation."
      elsif result[:applied] then "Added an expectation."
      else "Proposed a new expectation."
      end
    redirect_to edit_framework_path(@framework.framework_id), notice: notice
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  # PATCH /frameworks/:framework_id/expectations/:id
  def update
    authorize @framework, :suggest_edit?
    new_description = params.expect(behavioural_expectation: [ :description ])[:description]
    return head(:unprocessable_content) if new_description.blank?

    Operations::Frameworks::SuggestEdit.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        entity_type: "behavioural_expectation", entity_id: @expectation.expectation_id,
        field: "description", value: new_description, mode: framework_edit_mode.to_s
      }
    )

    render Views::Frameworks::Explorer::ExpectationTextFrame.new(
      # Re-resolve from a fresh graph — an auto-approved edit rewrote the
      # snapshot; in suggesting mode the value is unchanged and the pending
      # decoration carries the diff.
      expectation: graph_expectation(@expectation.expectation_id, reload: true) || @expectation,
      framework_id: @framework.framework_id,
      mode: :edit,
      pending_edit_count: pending_edits_on_expectation,
      pending_edit: latest_pending_edit
    ), layout: false
  rescue Operations::Base::ParameterError, RuntimeError
    head :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Resolve the expectation from the explorer graph, NOT the published read
  # model — an expectation authored in the current draft is deferred from
  # FrameworkState::BehaviouralExpectation (shape-changing) but lives in the
  # graph, and must still be inline-editable (Hard-Won Lesson 17). The graph is
  # per-framework, so finding the id in it also scopes to the authorized framework.
  def set_expectation
    @expectation = graph_expectation(params.expect(:id))
    head :not_found unless @expectation
  end

  def graph_expectation(expectation_id, reload: false)
    @explorer_graph = nil if reload
    explorer_graph.capability_categories.flat_map(&:capabilities).flat_map(&:expectations)
      .find { |e| e.expectation_id == expectation_id }
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(@framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end

  def pending_edits_on_expectation
    pending_edits_scope.count
  end

  def latest_pending_edit
    edit = pending_edits_scope.edits.where(field: "description").order(created_at: :desc).first
    return nil unless edit

    { suggested_value: edit.suggested_value,
      suggestion_id: edit.suggestion_id,
      created_at: edit.created_at }
  end

  def pending_edits_scope
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: "behavioural_expectation",
      target_entity_id: @expectation.expectation_id,
      status: "pending"
    )
  end
end
