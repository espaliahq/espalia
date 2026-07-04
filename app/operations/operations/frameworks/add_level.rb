# frozen_string_literal: true

# Adds a level to a role. **Shape-changing** — a new ordinal adds rating rows —
# so it requires a draft; the aggregate auto-opens one (`auto_opened: true`)
# when none is in progress, and the level stays deferred from the published
# read model until the version is published (ADR-16). In the explorer it
# renders immediately in edit mode (graph-sourced, wiggled); a ghost role's
# first level makes the role visible in view mode only after publish.
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#add_level?).
class Operations::Frameworks::AddLevel < Operations::Base
  description "Add a level to a role (owner/editor/lead only; opens/joins a draft, published on the next version)."
  category :write
  approval :mcp_client

  parameter :framework_id, String,   required: true
  parameter :role_id,      String,   required: true
  parameter :ordinal,      Integer,  required: true
  parameter :title,        String,   required: true
  parameter :code,         String,   required: true
  parameter :is_entry,     :boolean

  def policy_check
    authorize framework, :add_level?
  end

  # @return [Hash] { framework_id:, role_id:, level_id:, ordinal:, title: }
  def perform
    ensure_role!
    ensure_ordinal_free!

    level_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.add_level(
      framework.framework_id, level_id, params[:role_id],
      params[:ordinal], params[:title], params[:code],
      is_entry: params[:is_entry] || false
    )
    {
      framework_id: framework.framework_id, role_id: params[:role_id],
      level_id: level_id, ordinal: params[:ordinal], title: params[:title]
    }
  end

  private

  # Resolve the role from the ExplorerGraph — scoped to the authorized
  # framework (mcp-server.md Lesson 5) and inclusive of draft state, unlike the
  # published read model which defers draft-added levels (Lesson 17).
  def graph_role
    @graph_role ||= graph.role_families.flat_map(&:roles)
                         .find { |r| r.role_id == params[:role_id] }
  end

  def ensure_role!
    return if graph_role

    raise Operations::Base::ParameterError, "role_id not found in this framework"
  end

  # The merged-level grid keys rows by ordinal per role — a duplicate would
  # render two identical columns. The aggregate only guards level_id, so the
  # ordinal guard lives here, against the graph (which sees draft levels too).
  def ensure_ordinal_free!
    raise Operations::Base::ParameterError, "ordinal must be positive" unless params[:ordinal].positive?
    return if graph_role.levels.none? { |l| l.ordinal == params[:ordinal] }

    raise Operations::Base::ParameterError,
          "the role already has a level at ordinal #{params[:ordinal]}"
  end

  def graph
    @graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
               Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
