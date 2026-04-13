# frozen_string_literal: true

# Handles inline illustration create and edit submissions.
#
class Frameworks::IllustrationsController < ApplicationController
  before_action :set_framework
  before_action :set_illustration, only: [ :update ]

  # POST /frameworks/:framework_id/illustrations
  #
  # Routes all creates through suggest_create. Users with approval rights
  # for role_illustration (tier 1) are auto-approved — the illustration is
  # created immediately. Users without approval rights get a pending
  # suggestion that shows as a ghost entry until approved.
  def create
    authorize @framework, :submit_suggestion?
    ill_params = params.expect(illustration: [ :expectation_id, :role_id, :description ])
    expectation_id = ill_params[:expectation_id]
    role_id = ill_params[:role_id]
    description = ill_params[:description]

    suggestion_id = SecureRandom.uuid_v7
    ordinal = FrameworkState::RoleIllustration
      .where(expectation_id: expectation_id, role_id: role_id)
      .count + 1

    Frameworks::CommandHandler.new.suggest_create(
      @framework.framework_id,
      suggestion_id,
      "role_illustration",
      { role_id: role_id, description: description, ordinal: ordinal },
      parent_id: expectation_id,
      author_id: resolve_author_id,
      mode: :editing
    )

    suggestion = FrameworkState::SuggestedEdit.find_by!(suggestion_id: suggestion_id)

    if suggestion.status == "approved"
      render_created_turbo_stream(expectation_id, role_id, description)
    else
      render_pending_turbo_stream(suggestion, expectation_id, role_id)
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  # PATCH /frameworks/:framework_id/illustrations/:id
  def update
    authorize @framework, :suggest_edit?
    suggestion_id = SecureRandom.uuid_v7
    new_description = params.expect(illustration: [ :description ])[:description]

    Frameworks::CommandHandler.new.suggest_edit(
      @framework.framework_id,
      suggestion_id,
      "role_illustration",
      @illustration.illustration_id,
      "description",
      new_description,
      resolve_author_id
    )

    @illustration.reload

    render Views::Frameworks::Explorer::IllustrationFrame.new(
      illustration: @illustration,
      framework_id: @framework.framework_id
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

  def set_illustration
    @illustration = FrameworkState::RoleIllustration.find_by!(illustration_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Uses person_id for collaborator-based approval lookup, falls back to
  # user_id for tenant admins who may not have a person record.
  #
  # @return [String]
  def resolve_author_id
    (current_person&.id || current_user.id).to_s
  end

  # Renders turbo stream for an auto-approved illustration create.
  def render_created_turbo_stream(expectation_id, role_id, description)
    illustration = FrameworkState::RoleIllustration
      .where(expectation_id: expectation_id, role_id: role_id, description: description)
      .order(created_at: :desc).first!

    render turbo_stream: [
      turbo_stream.append(
        "illustrations-#{expectation_id}-#{role_id}",
        render_to_string(
          Views::Frameworks::Explorer::IllustrationFrame.new(
            illustration: illustration,
            framework_id: @framework.framework_id
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
            is_author: true
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
end
