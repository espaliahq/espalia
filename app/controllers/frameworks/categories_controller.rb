# frozen_string_literal: true

# Handles inline capability-category edits (name, description) submitted
# from the Framework Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController}.
#
class Frameworks::CategoriesController < ApplicationController
  include FrameworkEditMode

  before_action :set_framework
  before_action :set_category

  # PATCH /frameworks/:framework_id/categories/:id
  #
  # Only `name` is accepted — the turbo-frame response re-renders
  # CategoryNameFrame. Description edits need their own endpoint + frame
  # when the UI for it exists.
  def update
    authorize @framework, :suggest_edit?
    new_name = params.expect(capability_category: [ :name ])[:name]
    return head(:unprocessable_content) if new_name.blank?

    Frameworks::CommandHandler.new.suggest_edit(
      @framework.framework_id, SecureRandom.uuid_v7,
      "capability_category", @category.category_id,
      "name", new_name, resolve_author_id,
      mode: framework_edit_mode
    )

    @category.reload
    render Views::Frameworks::Explorer::CategoryNameFrame.new(
      category: @category,
      framework_id: @framework.framework_id,
      mode: :edit,
      pending_edit_count: pending_edits_on_category,
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

  def set_category
    @category = FrameworkState::CapabilityCategory.find_by!(
      framework_id: @framework.framework_id,
      category_id: params.expect(:id)
    )
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def resolve_author_id
    current_person.id.to_s
  end

  def pending_edits_on_category
    pending_edits_scope.count
  end

  def latest_pending_edit
    edit = pending_edits_scope.edits.where(field: "name").order(created_at: :desc).first
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
