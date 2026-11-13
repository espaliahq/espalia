# frozen_string_literal: true

# What the Org Graph editor operations share: finding a person's account in
# the tenant, and the list as it reads after a change.
module Operations::OrgGraph::EditorSupport
  private

  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_org_graph_editors?, policy_class: TenantPolicy
  end

  def account!
    TenantUser.find_by(person_id: params[:person_id].to_s.downcase) or
      raise Operations::Base::ParameterError, "person_id: that person has no account in this organisation"
  end

  # Admins may always edit, so they are listed apart from the editors an
  # admin chose.
  def editors_payload
    accounts = TenantUser.where(role: :admin).or(TenantUser.where(org_graph_editor: true)).includes(:person, :user)
    admins, editors = accounts.partition(&:admin?)
    { editors: editors.map { account_payload(it) }.sort_by { it[:name].to_s }, admins: admins.map { account_payload(it) }.sort_by { it[:name].to_s } }
  end

  def account_payload(account)
    { person_id: account.person_id, name: account.person&.name || account.user&.email }
  end
end
