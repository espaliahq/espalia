# frozen_string_literal: true

# Handles inline behavioural-expectation edits submitted from the Framework
# Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController}. Expectations expose only a
# `description` field — the level_ordinal/capability_id are grid-position
# and not directly edited.
#
class Frameworks::ExpectationsController < ApplicationController
  include FrameworkEditMode
  include InlineSuggestedEdits

  before_action :set_framework
  before_action :set_expectation, only: [ :update ]

  # POST /frameworks/:framework_id/expectations
  #
  # Authors a behavioural expectation in a previously-empty capability × level
  # cell via the matrix "+ Add expectation" affordance. Shape-changing —
  # restricted to edit-rights holders; redirects back to the edit page with the
  # new cell rendered.
  def create
    authorize @framework, :add_expectation?
    attrs = params.expect(behavioural_expectation: [ :capability_id, :level_ordinal, :description ])

    Operations::Frameworks::SetBehaviouralExpectation.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        capability_id: attrs[:capability_id],
        level_ordinal: attrs[:level_ordinal].to_i,
        description: attrs[:description].to_s
      }
    )
    redirect_to edit_framework_path(@framework.framework_id), notice: "Added an expectation."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  # PATCH /frameworks/:framework_id/expectations/:id
  def update
    authorize @framework, :suggest_edit?
    new_description = params.expect(behavioural_expectation: [ :description ])[:description]
    return head(:unprocessable_content) if new_description.blank?

    submit_inline_suggested_edit(
      framework_id: @framework.framework_id,
      entity_type: "behavioural_expectation", entity_id: @expectation.expectation_id,
      field: "description", value: new_description, author_id: resolve_author_id, mode: framework_edit_mode
    )

    @expectation.reload
    render Views::Frameworks::Explorer::ExpectationTextFrame.new(
      expectation: @expectation,
      framework_id: @framework.framework_id,
      mode: :edit,
      pending_edit_count: pending_edits_on_expectation,
      pending_edit: latest_pending_edit
    ), layout: false
  rescue ActiveRecord::RecordNotFound, RuntimeError
    head :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def set_expectation
    # Scope to the current framework via capability → category to prevent
    # a framework-A request targeting a framework-B expectation.
    @expectation = FrameworkState::BehaviouralExpectation
      .joins(capability: :category)
      .find_by!(
        expectation_id: params.expect(:id),
        framework_capability_categories: { framework_id: @framework.framework_id }
      )
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def resolve_author_id
    current_person.id.to_s
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
