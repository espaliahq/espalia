# frozen_string_literal: true

# The list the editor and planner tools return: the accounts holding a grant,
# each with when it took effect and who gave it, and the admins, who need none.
#
# The flag on tenant_users says who holds the grant; the TenantAccountGrants stream
# says since when and from whom. A flag the stream doesn't hold yet reads with
# those left nil until the deploy's reconcile records it.
module Operations::GrantHoldersPayload
  private

  def grant_holders_payload(grant, key)
    accounts = TenantUser.where(role: :admin).or(TenantUser.where(grant => true)).includes(:person, :user)
    admins, holders = accounts.partition(&:admin?)
    holdings = AccountGrants::Repository.new.load_grants.holdings(grant)
    granters = granter_names(holdings.values.filter_map(&:added_by_id))
    {
      key => holders.map { holder_payload(it, holdings[it.id], granters) }.sort_by { it[:name].to_s },
      admins: admins.map { account_payload(it) }.sort_by { it[:name].to_s }
    }
  end

  def holder_payload(account, holding, granters)
    account_payload(account).merge(
      since: holding&.since&.iso8601,
      added_by: holding&.added_by_id && (granters[holding.added_by_id] || Person::FORMER_MEMBER),
      already_held: holding&.already_held
    )
  end

  def account_payload(account)
    { person_id: account.person_id, name: account.person&.name || account.user&.email }
  end

  def granter_names(person_ids)
    Person.where(id: person_ids.uniq).pluck(:id, :name).to_h
  end
end
