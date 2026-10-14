# frozen_string_literal: true

# Inline rename of a role (PATCH) and creation of a new role (POST) from the
# Framework Explorer's edit-mode role tree. Direct org-structure edits
# (shape-preserving, applied live) — not the suggested-edit path. Gated by
# FrameworkPolicy#update_role? / #add_role?. (Code/track edits are exposed via
# the Operation/MCP; the inline UI only renames for now.)
#
class Frameworks::RolesController < ApplicationController
  include Frameworks::RoleTreeFamiliesFrame

  BLANK_NAME = "the name can’t be blank"

  before_action :set_framework
  before_action :set_role, only: [ :update ]

  # POST /frameworks/:framework_id/roles
  #
  # From the shared add-role modal (a family's "+ Add role" row). Re-renders
  # the `role-tree-families` frame so the new role appears under its family in
  # place, ghost-wiggled (no published levels yet), selection preserved.
  def create
    authorize @framework, :add_role?

    permitted = params.expect(role: [ :role_family_id, :name, :code, :track ])
    Operations::Frameworks::AddRole.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, **permitted.to_h.symbolize_keys }
    )

    render_role_tree_families_frame(@framework)
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  # PATCH /frameworks/:framework_id/roles/:id
  #
  # Serves both the inline name rename (re-renders the per-role name frame) and
  # the kebab's edit dialog (name + code + track — re-renders the
  # `role-tree-families` frame on the `Turbo-Frame` header, selection
  # preserved; the dialog separately asks the matrix to re-fetch, since code /
  # track ripple through the header badges).
  def update
    authorize @framework, :update_role?

    attrs = changed_role_attrs
    return render_name_frame(error: BLANK_NAME) if inline_rename? && attrs.key?(:name) && attrs[:name].blank?

    if attrs.present?
      Operations::Frameworks::UpdateRole.call(
        context: pundit_user,
        params: { framework_id: @framework.framework_id, role_id: @role.role_id, **attrs }
      )
    end

    if inline_rename?
      render_name_frame
    else
      render_role_tree_families_frame(@framework)
    end
  rescue Operations::Base::ParameterError => e
    inline_rename? ? render_name_frame(error: e.message) : head(:unprocessable_content)
  end

  private

  def inline_rename?
    request.headers["Turbo-Frame"] != FAMILIES_FRAME
  end

  # A rejected inline rename answers 422 WITH the frame: the message plus the
  # typed text, so the editor re-opens with it (Hard-Won Lesson 26).
  def render_name_frame(error: nil)
    render Views::Frameworks::Explorer::RoleNameFrame.new(
      role: @role.reload, framework_id: @framework.framework_id, mode: :edit,
      error: error, attempted_value: (params.dig(:role, :name).to_s if error)
    ), layout: false, status: (error ? :unprocessable_content : :ok)
  end

  # Only forward fields that actually changed (the update event is compacted,
  # so present keys read as "changed" in the activity feed). A blank name IS
  # forwarded so the operation rejects it (422 — a role can't be unnamed).
  def changed_role_attrs
    permitted = params.expect(role: [ :name, :code, :track ])
    attrs = {}
    if permitted.key?(:name) && (permitted[:name].blank? || permitted[:name] != @role.name)
      attrs[:name] = permitted[:name]
    end
    attrs[:code] = permitted[:code] if permitted.key?(:code) && permitted[:code] != @role.code
    attrs[:track] = permitted[:track] if permitted.key?(:track) && permitted[:track] != @role.track
    attrs
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Scope the lookup to this framework (via its role families) so a role id from
  # another framework can't be targeted here.
  def set_role
    family_ids = FrameworkState::RoleFamily.where(framework_id: @framework.framework_id).select(:role_family_id)
    @role = FrameworkState::Role.find_by!(role_family_id: family_ids, role_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
