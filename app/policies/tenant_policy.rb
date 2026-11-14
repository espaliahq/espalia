# frozen_string_literal: true

# Authorizes tenant-administration surfaces — the admin dashboard at
# /tenant, the theme editor at /tenant/theme, and the feedback export. Tenant members are
# denied; only tenant administrators (TenantUser#admin?) and global
# admins (User#global_admin?) can view or update.
#
class TenantPolicy < ApplicationPolicy
  # @return [Boolean] whether the viewer can see the tenant admin hub
  def show? = tenant_admin?

  # @return [Boolean] whether the viewer can edit the tenant theme
  def update_theme? = tenant_admin?

  # @return [Boolean] whether the viewer can rename the performance states
  #   for this tenant (display labels only — scoring policy lives on the
  #   framework and has its own bar)
  def update_scoring_vocabulary? = tenant_admin?

  # An admin's alone, and not an Org Graph editor's: how long a leaver's
  # identifiers are kept is the organisation's data-protection decision,
  # not a change to its structure.
  #
  # @return [Boolean] whether the viewer can set how long leavers are kept
  def update_retention_period? = tenant_admin?

  # Forgetting can't be undone, so an admin decides it, as they set the
  # retention period.
  #
  # @return [Boolean] whether the viewer can forget a leaver or turn on scheduled forgetting
  def forget_person? = tenant_admin?

  # An admin's alone: an editor may change the Org Graph but not choose who
  # else may.
  #
  # @return [Boolean] whether the viewer can list, add or remove Org Graph editors
  def manage_org_graph_editors? = tenant_admin?

  # Bands price every plan, so only an admin keeps them, and only an admin
  # reads them in full: a plan member sees a band's midpoint through the plan.
  #
  # @return [Boolean] whether the viewer can list, add, change or remove pay bands
  def manage_pay_bands? = tenant_admin?

  # Narrower than the cycle report's bar (which admits managers): the export
  # carries names and feedback text. A linked Person is required so every
  # export is attributable to someone in the audit log.
  #
  # @return [Boolean] whether the viewer can export the tenant's feedback
  def export_feedback? = tenant_admin? && person.present?
end
