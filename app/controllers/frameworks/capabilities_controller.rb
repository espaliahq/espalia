# frozen_string_literal: true

# Handles inline capability edits (name, description) submitted from the
# Framework Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController} — routes every edit through
# `suggest_edit` so audit + approval rules are consistent.
#
class Frameworks::CapabilitiesController < ApplicationController
  include FrameworkEditMode
  include Frameworks::SuggestionAuthority
  include Frameworks::WriteResponse

  before_action :set_framework
  before_action :set_capability, only: [ :update ]

  # POST /frameworks/:framework_id/capabilities
  #
  # Adds a new capability to a category (and optionally binds it to roles) via
  # the shared add-capability modal. Restricted to edit-rights holders.
  def create
    authorize @framework, :add_capability?
    attrs = params.expect(capability: [ :category_id, :name, :description, { role_ids: [] } ])

    result = Operations::Frameworks::AddCapability.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        category_id: attrs[:category_id],
        name: attrs[:name],
        description: attrs[:description].presence,
        role_ids: Array(attrs[:role_ids]).compact_blank
      }
    )

    render_write_streams(
      [ toast_stream("Added “#{attrs[:name]}”.") ] +
      capability_insert_streams(result[:capability_id], attrs[:category_id]) +
      draft_status_streams
    )
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_write_error(e.message)
  end

  # PATCH /frameworks/:framework_id/capabilities/:id
  #
  # Inline edit of a capability's `name` or `description` (whichever field the
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
        entity_type: "capability", entity_id: @capability.capability_id,
        field: field, value: value, mode: framework_edit_mode.to_s
      }
    )

    render frame_for(field), layout: false
  rescue ActiveRecord::RecordNotFound
    render_save_error(field, "this capability no longer exists \u2014 reload the page", value)
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
    permitted = params.expect(capability: [ :name, :description ])
    if permitted.key?(:name)
      [ "name", permitted[:name] ]
    elsif permitted.key?(:description)
      [ "description", permitted[:description] ]
    else
      [ nil, nil ]
    end
  end

  def frame_for(field, error: nil, attempted_value: nil)
    # Re-resolve from a fresh graph — an auto-approved edit rewrote the
    # snapshot; in suggesting mode the value is unchanged and the pending
    # decoration carries the diff.
    common = {
      capability: graph_capability(@capability.capability_id, reload: true) || @capability,
      framework_id: @framework.framework_id, mode: :edit,
      pending_edit_count: pending_count_for(field), pending_edit: latest_pending_edit_for(field),
      error: error, attempted_value: attempted_value
    }
    if field == "description"
      Views::Frameworks::Explorer::CapabilityDescriptionFrame.new(**common)
    else
      Views::Frameworks::Explorer::CapabilityNameFrame.new(**common)
    end
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Resolve the capability from the explorer graph, NOT the published read
  # model — a capability added in the current draft is deferred from
  # FrameworkState::Capability (shape-changing) but lives in the graph, and
  # must still be inline-editable. The graph is per-framework, so finding the
  # id in it also scopes the lookup to the authorized framework.
  def set_capability
    @capability = graph_capability(params.expect(:id))
    head :not_found unless @capability
  end

  def graph_capability(capability_id, reload: false)
    @explorer_graph = nil if reload
    explorer_graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.capability_id == capability_id }
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(@framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end

  def pending_count_for(field)
    pending_edits_scope.where(field: field).count
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
      target_entity_type: "capability",
      target_entity_id: @capability.capability_id,
      status: "pending"
    )
  end
end
