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

    created_entity_id = Frameworks::CommandHandler.new.suggest_create(
      @framework.framework_id,
      suggestion_id,
      "role_illustration",
      { role_id: role_id, description: description, ordinal: ordinal },
      parent_id: expectation_id,
      author_id: resolve_author_id,
      mode: :editing
    )

    if created_entity_id
      render_created_turbo_stream(created_entity_id, expectation_id, role_id)
    else
      suggestion = FrameworkState::SuggestedEdit.find_by!(suggestion_id: suggestion_id)
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

  # Returns the current Person's id — the canonical author identity for
  # framework suggestions. ApplicationController#auto_link_person guarantees
  # every authenticated TenantUser has a linked Person, so current_person
  # is present here.
  #
  # @return [String]
  def resolve_author_id
    current_person.id.to_s
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
