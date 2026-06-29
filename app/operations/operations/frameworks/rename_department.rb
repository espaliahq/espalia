# frozen_string_literal: true

# Renames a department grouping across every role family currently carrying it.
# A department is a free-text label, not an entity — so "rename the department"
# is a bulk relabel: each affected family gets an UpdateRoleFamily(department:).
# A blank `to` ungroups all the affected families.
#
# Shape-preserving — applies live (no draft). Gated by
# FrameworkPolicy#update_role_family? (the same edit-rights bar as the per-family
# edit). Write — :mcp_client: a relabel is non-destructive and reversible (rename
# back), the same risk profile as UpdateRoleFamily, just applied to the group.
class Operations::Frameworks::RenameDepartment < Operations::Base
  description "Rename a department grouping across all its role families (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :from,         String, required: true
  parameter :to,           String

  def policy_check
    authorize framework, :update_role_family?
  end

  # @return [Hash] { framework_id:, from:, to:, renamed_count: }
  def perform
    raise Operations::Base::ParameterError, "provide the department to rename" if params[:from].blank?

    # The new label is always applied (relabel or, when blank, ungroup) — never
    # an "omit"; "" clears via UpdateRoleFamily's clear semantics.
    to_value = params[:to].to_s
    raise Operations::Base::ParameterError, "the department is already named that" if to_value == params[:from]

    handler = Frameworks::CommandHandler.new
    role_family_ids = FrameworkState::RoleFamily
      .where(framework_id: framework.framework_id, department: params[:from])
      .pluck(:role_family_id)
    role_family_ids.each do |role_family_id|
      handler.update_role_family(framework.framework_id, role_family_id, department: to_value)
    end

    { framework_id: framework.framework_id, from: params[:from], to: to_value, renamed_count: role_family_ids.size }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
