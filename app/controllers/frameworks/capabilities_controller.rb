# frozen_string_literal: true

# Handles inline capability edits (name, description) submitted from the
# Framework Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController} — routes every edit through
# `suggest_edit` so audit + approval rules are consistent.
#
class Frameworks::CapabilitiesController < ApplicationController
  include FrameworkEditMode

  before_action :set_framework
  before_action :set_capability, only: [ :update ]

  # POST /frameworks/:framework_id/capabilities
  #
  # Adds a new capability to a category (and optionally binds it to roles) via
  # the shared add-capability modal. Restricted to edit-rights holders.
  def create
    authorize @framework, :add_capability?
    attrs = params.expect(capability: [ :category_id, :name, :description, { role_ids: [] } ])

    Operations::Frameworks::AddCapability.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        category_id: attrs[:category_id],
        name: attrs[:name],
        description: attrs[:description].presence,
        role_ids: Array(attrs[:role_ids]).compact_blank
      }
    )
    redirect_to edit_framework_path(@framework.framework_id), notice: "Added “#{attrs[:name]}”."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

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
      pending_edit_count: pending_edits_on_capability,
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
      target_entity_type: "capability",
      target_entity_id: @capability.capability_id,
      status: "pending"
    )
  end
end
