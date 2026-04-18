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
  def update
    authorize @framework, :suggest_edit?
    attrs = params.expect(capability_category: [ :name, :description ])
    field, value = first_edited_field(attrs)
    return head(:unprocessable_content) if field.nil?

    Frameworks::CommandHandler.new.suggest_edit(
      @framework.framework_id, SecureRandom.uuid_v7,
      "capability_category", @category.category_id,
      field, value, resolve_author_id,
      mode: framework_edit_mode
    )

    @category.reload
    render Views::Frameworks::Explorer::CategoryNameFrame.new(
      category: @category,
      framework_id: @framework.framework_id,
      mode: :edit,
      pending_edit_count: pending_edits_on_category
    ), layout: false
  rescue ActiveRecord::RecordNotFound
    head :unprocessable_content
  rescue RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def set_category
    @category = FrameworkState::CapabilityCategory.find_by!(category_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def resolve_author_id
    current_person.id.to_s
  end

  def pending_edits_on_category
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: "capability_category",
      target_entity_id: @category.category_id,
      status: "pending"
    ).count
  end

  def first_edited_field(attrs)
    %i[name description].each do |candidate|
      value = attrs[candidate]
      return [ candidate.to_s, value ] if value.present?
    end
    [ nil, nil ]
  end
end
