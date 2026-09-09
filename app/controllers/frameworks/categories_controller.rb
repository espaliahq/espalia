# frozen_string_literal: true

# Handles inline capability-category edits (name, description) submitted
# from the Framework Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController}.
#
class Frameworks::CategoriesController < ApplicationController
  include FrameworkEditMode

  before_action :set_framework
  before_action :set_category, only: [ :update ]

  # POST /frameworks/:framework_id/categories
  #
  # Adds a new (empty) capability category via the shared add-category modal.
  # Restricted to edit-rights holders.
  def create
    authorize @framework, :add_category?
    attrs = params.expect(category: [ :name, :description ])

    Operations::Frameworks::AddCategory.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        name: attrs[:name],
        description: attrs[:description].presence
      }
    )
    redirect_to edit_framework_path(@framework.framework_id), notice: "Added category “#{attrs[:name]}”."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  # PATCH /frameworks/:framework_id/categories/:id
  #
  # Inline edit of a category's `name` or `description` (whichever field the
  # inline editor submitted), routed through suggest_edit so audit + approval
  # rules are consistent. The turbo-frame response re-renders the matching
  # frame (name or description).
  # A rejected save re-renders the frame with the message + the attempted value
  # (422) instead of answering bodyless, which Turbo ignores (Hard-Won Lesson 26).
  def update
    authorize @framework, :suggest_edit?
    field, value = edited_field
    return render_save_error(field || "name", "the text can\u2019t be blank", value) if value.blank?

    Operations::Frameworks::SuggestEdit.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        entity_type: "capability_category", entity_id: @category.category_id,
        field: field, value: value, mode: framework_edit_mode.to_s
      }
    )

    @category.reload
    render frame_for(field), layout: false
  rescue ActiveRecord::RecordNotFound
    render_save_error(field, "this category no longer exists \u2014 reload the page", value)
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_save_error(field, e.message, value)
  end

  private

  def render_save_error(field, message, attempted_value)
    render frame_for(field, error: message, attempted_value: attempted_value),
           layout: false, status: :unprocessable_content
  end

  # The single field the inline editor submitted, with its raw value. Blank
  # values are rejected by the caller — the SuggestedEdit read model requires a
  # suggested_value, so a blank submission can't become a suggestion.
  # Returns [field, value]; field is nil when neither key was sent.
  def edited_field
    permitted = params.expect(capability_category: [ :name, :description ])
    if permitted.key?(:name)
      [ "name", permitted[:name] ]
    elsif permitted.key?(:description)
      [ "description", permitted[:description] ]
    else
      [ nil, nil ]
    end
  end

  def frame_for(field, error: nil, attempted_value: nil)
    common = {
      category: @category, framework_id: @framework.framework_id, mode: :edit,
      pending_edit_count: pending_count_for(field), pending_edit: latest_pending_edit_for(field),
      error: error, attempted_value: attempted_value
    }
    if field == "description"
      Views::Frameworks::Explorer::CategoryDescriptionFrame.new(**common)
    else
      Views::Frameworks::Explorer::CategoryNameFrame.new(**common)
    end
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def set_category
    @category = FrameworkState::CapabilityCategory.find_by!(
      framework_id: @framework.framework_id,
      category_id: params.expect(:id),
      status: "active"
    )
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Count from the same `.edits` scope the latest-edit query uses, so the badge
  # count and the rendered inline diff can't diverge (creates/deletes carry a
  # nil field so they're excluded either way — this just keeps the two aligned).
  def pending_count_for(field)
    pending_edits_scope.edits.where(field: field).count
  end

  def latest_pending_edit_for(field)
    edit = pending_edits_scope.edits.where(field: field).order(created_at: :desc).first
    return nil unless edit

    { suggested_value: edit.suggested_value,
      suggestion_id: edit.suggestion_id,
      created_at: edit.created_at }
  end

  def pending_edits_scope
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: "capability_category",
      target_entity_id: @category.category_id,
      status: "pending"
    )
  end
end
