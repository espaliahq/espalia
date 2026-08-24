# frozen_string_literal: true

# Handles inline illustration create and edit submissions.
#
class Frameworks::IllustrationsController < ApplicationController
  include FrameworkEditMode
  include Frameworks::SuggestionAuthority

  before_action :set_framework
  before_action :set_illustration, only: [ :update ]

  # POST /frameworks/:framework_id/illustrations
  #
  # Routes all creates through the suggest/approve path
  # ({Operations::Frameworks::SuggestCreate}). Users with approval rights
  # for role_illustration (tier 1) are auto-approved in editing mode — the
  # illustration is created immediately. Users without approval rights (or in
  # suggesting mode) get a pending suggestion that shows as a ghost entry
  # until approved.
  def create
    authorize @framework, :submit_suggestion?
    ill_params = params.expect(illustration: [ :expectation_id, :role_id, :description ])
    expectation_id = ill_params[:expectation_id]
    role_id = ill_params[:role_id]
    description = ill_params[:description]

    # No ordinal here — the aggregate allocates the next one inside the
    # event-serialized write path when the create is applied, so concurrent
    # creates can't race a read-model COUNT into duplicate ordinals.
    result = Operations::Frameworks::SuggestCreate.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        entity_type: "role_illustration",
        proposed_attributes: { role_id: role_id, description: description },
        parent_id: expectation_id,
        mode: framework_edit_mode.to_s
      }
    )

    if result[:applied]
      render_created_turbo_stream(result[:created_entity_id], expectation_id, role_id)
    else
      suggestion = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
      render_pending_turbo_stream(suggestion, expectation_id, role_id)
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue Operations::Base::ParameterError, RuntimeError
    head :unprocessable_content
  end

  # PATCH /frameworks/:framework_id/illustrations/:id
  def update
    authorize @framework, :suggest_edit?
    new_description = params.expect(illustration: [ :description ])[:description]

    Operations::Frameworks::SuggestEdit.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        entity_type: "role_illustration", entity_id: @illustration.illustration_id,
        field: "description", value: new_description, mode: framework_edit_mode.to_s
      }
    )

    @illustration.reload

    render Views::Frameworks::Explorer::IllustrationFrame.new(
      illustration: @illustration,
      framework_id: @framework.framework_id,
      mode: :edit,
      pending_edit_count: pending_edits_on_illustration,
      pending_edit: latest_pending_edit,
      # The frame swap must not drop the ↑/↓ chevrons or the approval kebab
      # (Hard-Won Lesson 13/16 class — controller responses re-thread every
      # affordance-gating flag). The authority costs two collaborator queries,
      # so it's only resolved when a pending edit exists for the kebab to act
      # on — the common auto-applied edit skips it.
      can_reorder: can_reorder_illustrations?,
      approval_authority: pending_edit_approval_authority
    ), layout: false
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue Operations::Base::ParameterError, RuntimeError
    head :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def set_illustration
    @illustration = FrameworkState::RoleIllustration.find_by!(illustration_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def pending_edits_on_illustration
    # Proposals only (defensive symmetry with the expectation frame — an
    # illustration can't carry a clarification today).
    pending_edits_scope.proposals.count
  end

  def latest_pending_edit
    return @latest_pending_edit if defined?(@latest_pending_edit)

    edit = pending_edits_scope.edits.where(field: "description").order(created_at: :desc).first
    @latest_pending_edit = edit && {
      suggested_value: edit.suggested_value,
      suggestion_id: edit.suggestion_id,
      created_at: edit.created_at
    }
  end

  # The kebab only renders against a pending edit, so the authority (two
  # collaborator queries) is skipped when there is nothing to approve.
  def pending_edit_approval_authority
    return Frameworks::SuggestionApprovalAuthority.none unless latest_pending_edit

    framework_suggestion_approval_authority
  end

  def pending_edits_scope
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: "role_illustration",
      target_entity_id: @illustration.illustration_id,
      status: "pending"
    )
  end

  # Renders turbo stream for an auto-approved illustration create.
  #
  # @param illustration_id [String] UUID returned by the aggregate on approval
  # @param expectation_id [String]
  # @param role_id [String]
  def render_created_turbo_stream(illustration_id, expectation_id, role_id)
    illustration = FrameworkState::RoleIllustration.find_by!(illustration_id: illustration_id)

    render turbo_stream: [
      turbo_stream.append(
        "illustrations-#{expectation_id}-#{role_id}",
        render_to_string(
          Views::Frameworks::Explorer::IllustrationFrame.new(
            illustration: illustration,
            framework_id: @framework.framework_id,
            mode: :edit,
            can_reorder: can_reorder_illustrations?
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "new-illustration-#{expectation_id}-#{role_id}",
        render_to_string(
          Views::Frameworks::Explorer::NewIllustrationFrame.new(
            expectation_id: expectation_id,
            role_id: role_id,
            framework_id: @framework.framework_id
          ),
          layout: false
        )
      )
    ]
  end

  # Renders turbo stream for a pending illustration suggestion (ghost entry).
  def render_pending_turbo_stream(suggestion, expectation_id, role_id)
    render turbo_stream: [
      turbo_stream.append(
        "illustrations-#{expectation_id}-#{role_id}",
        render_to_string(
          Views::Frameworks::Explorer::PendingIllustrationFrame.new(
            suggestion: suggestion,
            framework_id: @framework.framework_id,
            is_author: true,
            # A pending create always exists here, so the kebab gate is live —
            # re-thread the authority (Hard-Won Lesson 13/16 class).
            approval_authority: framework_suggestion_approval_authority
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "new-illustration-#{expectation_id}-#{role_id}",
        render_to_string(
          Views::Frameworks::Explorer::NewIllustrationFrame.new(
            expectation_id: expectation_id,
            role_id: role_id,
            framework_id: @framework.framework_id
          ),
          layout: false
        )
      )
    ]
  end

  # Whether the re-rendered frame should carry the ↑/↓ move chevrons — the
  # initial render gates on can_edit_structure (plus list size, which the
  # UL-level controller makes moot for a lone item: moving first-up / last-down
  # no-ops), so the swap mirrors the policy half of that gate.
  def can_reorder_illustrations?
    policy(@framework).reorder_illustrations?
  end
end
