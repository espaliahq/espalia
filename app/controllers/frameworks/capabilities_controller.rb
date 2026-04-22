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
  #
  # The turbo-frame response only knows how to re-render the capability name
  # (CapabilityNameFrame). Only accept `name` here — description edits need
  # their own endpoint + frame when that UI is built.
  def update
    authorize @framework, :suggest_edit?
    new_name = params.expect(capability: [ :name ])[:name]
    return head(:unprocessable_content) if new_name.blank?

    Frameworks::CommandHandler.new.suggest_edit(
      @framework.framework_id, SecureRandom.uuid_v7,
      "capability", @capability.capability_id,
      "name", new_name, resolve_author_id,
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
    # Scope to the current framework so a request for framework A can't
    # target a capability that belongs to framework B in the same tenant.
    @capability = FrameworkState::Capability.joins(:category)
      .find_by!(
        capability_id: params.expect(:id),
        framework_capability_categories: { framework_id: @framework.framework_id }
      )
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
end
