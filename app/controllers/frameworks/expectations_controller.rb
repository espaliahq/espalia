# frozen_string_literal: true

# Handles inline behavioural-expectation edits submitted from the Framework
# Explorer's edit mode. Mirrors the shape of
# {Frameworks::IllustrationsController}. Expectations expose only a
# `description` field — the level_ordinal/capability_id are grid-position
# and not directly edited.
#
class Frameworks::ExpectationsController < ApplicationController
  before_action :set_framework
  before_action :set_expectation

  # PATCH /frameworks/:framework_id/expectations/:id
  def update
    authorize @framework, :suggest_edit?
    new_description = params.expect(behavioural_expectation: [ :description ])[:description]
    return head(:unprocessable_content) if new_description.blank?

    Frameworks::CommandHandler.new.suggest_edit(
      @framework.framework_id, SecureRandom.uuid_v7,
      "behavioural_expectation", @expectation.expectation_id,
      "description", new_description, resolve_author_id
    )

    @expectation.reload
    render Views::Frameworks::Explorer::ExpectationTextFrame.new(
      expectation: @expectation,
      framework_id: @framework.framework_id,
      mode: :edit
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

  def set_expectation
    @expectation = FrameworkState::BehaviouralExpectation.find_by!(expectation_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def resolve_author_id
    current_person.id.to_s
  end
end
