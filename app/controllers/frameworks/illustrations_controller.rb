# frozen_string_literal: true

# Handles inline illustration edit submissions.
#
# Accepts PATCH requests from the inline_editor Stimulus controller,
# creates a suggested edit via the command handler, and returns
# the updated illustration as a Turbo Frame.
#
# Authorization is enforced in the command handler (not here) —
# can_approve? derives from aggregate state.
#
class Frameworks::IllustrationsController < ApplicationController
  before_action :set_illustration

  # PATCH /frameworks/:framework_id/illustrations/:id
  def update
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

  def set_illustration
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
    @illustration = FrameworkState::RoleIllustration.find_by!(
      illustration_id: params.expect(:id)
    )
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
