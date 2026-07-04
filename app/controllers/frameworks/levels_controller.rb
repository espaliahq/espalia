# frozen_string_literal: true

# Inline rename of a level title (PATCH, from the edit-mode matrix header) and
# creation of a new level (POST, from the role row's add-level modal). Direct
# org-structure edits — not the suggested-edit path. Rename is shape-preserving
# (applies live); **adding is shape-changing** — the aggregate auto-opens a
# draft and the level publishes with the next version. Gated by
# FrameworkPolicy#update_level? / #add_level?. (Code/entry-flag inline edits are
# exposed via the Operation/MCP; the inline UI only renames the title.)
#
class Frameworks::LevelsController < ApplicationController
  before_action :set_framework
  before_action :set_level, only: [ :update ]

  # POST /frameworks/:framework_id/levels
  #
  # Redirects back to the edit explorer (full render — the new draft column,
  # draft pill, and flash appear together), preserving the role selection the
  # add-level form threaded through via `tree-scope-fields`.
  def create
    authorize @framework, :add_level?

    attrs = params.expect(level: [ :role_id, :ordinal, :title, :code, :is_entry ])
    Operations::Frameworks::AddLevel.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        role_id: attrs[:role_id],
        # Number inputs submit strings; the operation's Integer param is strict.
        ordinal: attrs[:ordinal].to_i,
        title: attrs[:title], code: attrs[:code],
        is_entry: attrs[:is_entry]
      }
    )

    redirect_to edit_framework_path(@framework.framework_id, **selection_params),
                notice: "Added level “#{attrs[:title]}” (L#{attrs[:ordinal]}) to the draft."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id, **selection_params), alert: e.message
  end

  # PATCH /frameworks/:framework_id/levels/:id
  def update
    authorize @framework, :update_level?

    Operations::Frameworks::UpdateLevel.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        level_id: @level.level_id,
        title: params.expect(level: [ :title ])[:title]
      }
    )

    render Views::Frameworks::Explorer::LevelTitleFrame.new(
      level_id: @level.level_id, title: @level.reload.title,
      framework_id: @framework.framework_id, mode: :edit
    ), layout: false
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  private

  # The roles[]/track selection the form carried (injected at submit by
  # tree-scope-fields) — threaded onto the redirect so checkboxes stay checked.
  def selection_params
    { roles: Array.wrap(params[:roles]).select(&:present?).presence,
      track: params[:track].presence }.compact
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Scope the lookup to this framework (via its role families → roles) so a level
  # id from another framework can't be targeted here.
  def set_level
    family_ids = FrameworkState::RoleFamily.where(framework_id: @framework.framework_id).select(:role_family_id)
    role_ids = FrameworkState::Role.where(role_family_id: family_ids).select(:role_id)
    @level = FrameworkState::Level.find_by!(role_id: role_ids, level_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
