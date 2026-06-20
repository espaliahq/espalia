# frozen_string_literal: true

# Inline rename of a level title from the Framework Explorer's edit-mode matrix
# header. Direct org-structure edit (shape-preserving, applied live) — not the
# suggested-edit path. Gated by FrameworkPolicy#update_level?. (Code/entry-flag
# edits are exposed via the Operation/MCP; the inline UI only renames the title.)
#
class Frameworks::LevelsController < ApplicationController
  before_action :set_framework

  # PATCH /frameworks/:framework_id/levels/:id
  def update
    authorize @framework, :update_level?

    Operations::Frameworks::UpdateLevel.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        level_id: params.expect(:id),
        title: params.expect(level: [ :title ])[:title]
      }
    )

    render Views::Frameworks::Explorer::LevelTitleFrame.new(
      level_id: level.level_id, title: level.title,
      framework_id: @framework.framework_id, mode: :edit
    ), layout: false
  rescue Operations::Base::ParameterError, RuntimeError
    head :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Scope the lookup to this framework (via its role families → roles) so a level
  # id from another framework can't be re-rendered here.
  def level
    family_ids = FrameworkState::RoleFamily.where(framework_id: @framework.framework_id).select(:role_family_id)
    role_ids = FrameworkState::Role.where(role_family_id: family_ids).select(:role_id)
    FrameworkState::Level.find_by!(role_id: role_ids, level_id: params.expect(:id))
  end
end
