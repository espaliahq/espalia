# frozen_string_literal: true

# Handles inline capability edits (name, description) submitted from the
# Framework Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController} — routes every edit through
# `suggest_edit` so audit + approval rules are consistent.
#
class Frameworks::CapabilitiesController < ApplicationController
  include FrameworkEditMode

  before_action :set_framework
  before_action :set_capability

  # PATCH /frameworks/:framework_id/capabilities/:id
  def update
    authorize @framework, :suggest_edit?
    attrs = params.expect(capability: [ :name, :description ])
    field, value = first_edited_field(attrs)
    return head(:unprocessable_content) if field.nil?

    Frameworks::CommandHandler.new.suggest_edit(
      @framework.framework_id, SecureRandom.uuid_v7,
      "capability", @capability.capability_id,
      field, value, resolve_author_id,
      mode: framework_edit_mode
    )

    @capability.reload
    render Views::Frameworks::Explorer::CapabilityNameFrame.new(
      capability: @capability,
      framework_id: @framework.framework_id,
      mode: :edit,
      pending_edit_count: pending_edits_on_capability
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

  def set_capability
    @capability = FrameworkState::Capability.find_by!(capability_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def resolve_author_id
    current_person.id.to_s
  end

  def pending_edits_on_capability
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: "capability",
      target_entity_id: @capability.capability_id,
      status: "pending"
    ).count
  end

  # Picks the first present field from the permitted attrs so clients can
  # post a single-field payload without explicitly declaring which field
  # they mean.
  def first_edited_field(attrs)
    %i[name description].each do |candidate|
      value = attrs[candidate]
      return [ candidate.to_s, value ] if value.present?
    end
    [ nil, nil ]
  end
end
