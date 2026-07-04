# frozen_string_literal: true

# Level management from the Framework Explorer's edit mode:
#
# - `index` — the **levels editor** frame (role-row kebab → "Edit levels…"): a
#   binding-editor-style list of the role's levels (title / code / entry flag)
#   that re-renders in place on every action. Graph-sourced, so draft-added
#   levels are editable too (Lesson 17).
# - `update` — a row save from the editor (re-renders the frame), or the inline
#   title rename from the matrix header (re-renders the title frame).
# - `create` — a new level, from the editor's add row (re-renders the frame) or
#   the role row's "+ level" modal (redirects back to the edit explorer).
#
# Direct org-structure edits — not the suggested-edit path. Title/code/entry
# edits are shape-preserving (apply live); **adding is shape-changing** — the
# aggregate auto-opens a draft and the level publishes with the next version.
# Gated by FrameworkPolicy#update_level? / #add_level?.
#
# **Entry flag is radio-with-clear:** setting a level as entry clears the flag
# from the role's other levels (one UpdateLevel dispatch each) — a web-layer
# convenience over the per-level Operation, like evidence multi-send; MCP
# parity is untouched.
class Frameworks::LevelsController < ApplicationController
  EDITOR_FRAME = "level-editor"

  before_action :set_framework
  before_action :set_graph_role_and_level, only: [ :update ]

  # GET /frameworks/:framework_id/levels?role_id=…
  #
  # The levels-editor frame body for one role.
  def index
    authorize @framework, :update_level?

    role = graph_role(params.expect(:role_id))
    return head :not_found unless role

    render_editor_frame(role)
  end

  # POST /frameworks/:framework_id/levels
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

    if editor_request?
      render_editor_frame(graph_role(attrs[:role_id], reload: true))
    else
      redirect_to edit_framework_path(@framework.framework_id, **selection_params),
                  notice: "Added level “#{attrs[:title]}” (L#{attrs[:ordinal]}) to the draft."
    end
  rescue Operations::Base::ParameterError, RuntimeError => e
    if editor_request?
      # A bad role_id reaches this rescue (the operation rejects it) — there is
      # no role to render an editor for, so 404 instead of crashing the frame.
      role = graph_role(attrs[:role_id], reload: true)
      return head :not_found unless role

      render_editor_frame(role, error: e.message, status: :unprocessable_content)
    else
      redirect_to edit_framework_path(@framework.framework_id, **selection_params), alert: e.message
    end
  end

  # PATCH /frameworks/:framework_id/levels/:id
  def update
    authorize @framework, :update_level?

    attrs = changed_level_attrs
    if attrs.present?
      # One DB transaction so an entry transfer (set + clear-others) is
      # all-or-nothing — a mid-loop failure can't leave two entry badges.
      ApplicationRecord.transaction do
        Operations::Frameworks::UpdateLevel.call(
          context: pundit_user,
          params: { framework_id: @framework.framework_id, level_id: @level.level_id, **attrs }
        )
        clear_other_entry_levels if ActiveModel::Type::Boolean.new.cast(attrs[:is_entry])
      end
    end

    if editor_request?
      render_editor_frame(graph_role(@role.role_id, reload: true))
    else
      render Views::Frameworks::Explorer::LevelTitleFrame.new(
        level_id: @level.level_id, title: attrs[:title].presence || @level.title,
        framework_id: @framework.framework_id, mode: :edit
      ), layout: false
    end
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  private

  def editor_request?
    request.headers["Turbo-Frame"] == EDITOR_FRAME
  end

  def render_editor_frame(role, error: nil, status: :ok)
    render Views::Frameworks::Explorer::LevelEditorFrame.new(
      framework_id: @framework.framework_id, role: role, error: error
    ), layout: false, status: status
  end

  # Radio-with-clear: the role's other entry levels lose the flag when this one
  # gains it. @role is the pre-update graph node, so the just-updated level is
  # excluded by id, not by (stale) flag state.
  def clear_other_entry_levels
    @role.levels.each do |level|
      next if level.level_id == @level.level_id || !level.is_entry

      Operations::Frameworks::UpdateLevel.call(
        context: pundit_user,
        params: { framework_id: @framework.framework_id, level_id: level.level_id, is_entry: false }
      )
    end
  end

  # Only forward fields that actually changed (present keys read as "changed"
  # in the activity feed). A blank title IS forwarded so the operation rejects
  # it when it's the only field (a level can't be untitled).
  def changed_level_attrs
    permitted = params.expect(level: [ :title, :code, :is_entry ])
    attrs = {}
    if permitted.key?(:title) && (permitted[:title].blank? || permitted[:title] != @level.title)
      attrs[:title] = permitted[:title]
    end
    attrs[:code] = permitted[:code] if permitted.key?(:code) && permitted[:code] != @level.code
    if permitted.key?(:is_entry) &&
       ActiveModel::Type::Boolean.new.cast(permitted[:is_entry]) != @level.is_entry
      attrs[:is_entry] = permitted[:is_entry]
    end
    attrs
  end

  # The roles[]/track selection the "+ level" modal carried (injected at submit
  # by tree-scope-fields) — threaded onto the redirect so checkboxes stay
  # checked.
  def selection_params
    { roles: Array.wrap(params[:roles]).select(&:present?).presence,
      track: params[:track].presence }.compact
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Resolve the level (and its role) from the ExplorerGraph — scoped to this
  # framework by construction and inclusive of draft-added levels, which the
  # published read model defers until publish (Lesson 17).
  def set_graph_role_and_level
    level_id = params.expect(:id)
    graph.role_families.flat_map(&:roles).each do |role|
      level = role.levels.find { |l| l.level_id == level_id }
      next unless level

      @role = role
      @level = level
      return
    end
    head :not_found
  end

  # @param reload [Boolean] force a fresh graph read (after a write rewrote the
  #   snapshot)
  def graph_role(role_id, reload: false)
    @graph = nil if reload
    graph.role_families.flat_map(&:roles).find { |r| r.role_id == role_id }
  end

  def graph
    @graph ||= Frameworks::ExplorerGraph.load(@framework.framework_id) ||
               Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end
end
