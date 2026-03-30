# frozen_string_literal: true

# Handles inline illustration create and edit submissions.
#
class Frameworks::IllustrationsController < ApplicationController
  before_action :set_framework
  before_action :set_illustration, only: [ :update ]

  # POST /frameworks/:framework_id/illustrations
  def create
    authorize @framework, :create_illustration?
    ill_params = params.expect(illustration: [ :expectation_id, :role_id, :description ])
    expectation_id = ill_params[:expectation_id]
    role_id = ill_params[:role_id]
    description = ill_params[:description]

    illustration_id = SecureRandom.uuid_v7
    stable_id = SecureRandom.uuid_v7
    ordinal = FrameworkState::RoleIllustration
      .where(expectation_id: expectation_id, role_id: role_id)
      .count + 1

    Frameworks::CommandHandler.new.add_role_illustration(
      @framework.framework_id,
      illustration_id,
      stable_id,
      expectation_id,
      role_id,
      ordinal,
      description
    )

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
      current_user.id.to_s
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
end
