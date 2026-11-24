# frozen_string_literal: true

# Handles commands for a tenant's account grants and roles.
#
# Each command names the account and the grant or role; the date is today in
# the tenant's time zone unless the caller gives one.
#
class AccountGrants::CommandHandler
  # @param repository [AccountGrants::Repository]
  def initialize(repository: AccountGrants::Repository.new)
    @repository = repository
  end

  # @param grant [Symbol] one of {AccountGrants::Aggregate::GRANTS}
  # @param account [TenantUser]
  # @param added_by_id [String, nil] person_id of the actor
  # @param already_held [Boolean] true when recording a grant held before it was an event
  # @param effective_on [Date, nil]
  # @return [AccountGrants::Aggregate]
  def add(grant, account, added_by_id: nil, already_held: false, effective_on: nil)
    @repository.with_grants do |grants|
      settle(grants, grant, account.id, account.person_id, effective_on)
      grants.add(grant, tenant_user_id: account.id, person_id: account.person_id,
                 effective_on: effective_on || today, added_by_id:, already_held:)
    end
  end

  # Removes a grant from an account, or from one destroyed since it was given.
  #
  # @param grant [Symbol] one of {AccountGrants::Aggregate::GRANTS}
  # @param tenant_user_id [String]
  # @param person_id [String, nil]
  # @param removed_by_id [String, nil] person_id of the actor
  # @param effective_on [Date, nil]
  # @return [AccountGrants::Aggregate]
  def remove(grant, tenant_user_id:, person_id:, removed_by_id: nil, effective_on: nil)
    @repository.with_grants do |grants|
      settle(grants, grant, tenant_user_id, person_id, effective_on)
      grants.remove(grant, tenant_user_id:, person_id:, effective_on: effective_on || today, removed_by_id:)
    end
  end

  # Sets an account's role, after recording every role the table holds that
  # the stream doesn't, so the last-admin check counts the admins there are.
  # The live accounts stay share-locked until it commits, so a forget can't
  # take an admin the check has counted.
  #
  # @param account [TenantUser]
  # @param role [String, Symbol] one of {AccountGrants::Aggregate::ROLES}
  # @param set_by_id [String, nil] person_id of the actor
  # @param effective_on [Date, nil]
  # @return [AccountGrants::Aggregate]
  # @raise [AccountGrants::Aggregate::LastAdmin] when it would demote the last admin
  def set_role(account, role, set_by_id: nil, effective_on: nil)
    @repository.with_grants do |grants|
      hold_live_accounts
      AccountGrants::RoleReconciliation.new(ActsAsTenant.current_tenant, repository: @repository).reconcile(grants)
      grants.set_role(tenant_user_id: account.id, person_id: account.person_id, role:,
                      effective_on: effective_on || today, set_by_id:)
    end
  end

  # Records the role of an account just inserted, in the transaction that
  # inserted it.
  #
  # @param account [TenantUser]
  # @param set_by_id [String, nil] person_id of the actor
  # @return [AccountGrants::Aggregate]
  def record_new_account(account, set_by_id: nil)
    @repository.with_grants do |grants|
      grants.set_role(tenant_user_id: account.id, person_id: account.person_id, role: account.role,
                      effective_on: today, set_by_id:)
    end
  end

  private

  # Lock order: the grants stream, then tenant_users rows. A forget takes the
  # person's row, then its tenant_users rows, and never the grants lock; if it
  # ever writes to this stream, it must take the grants lock before those rows.
  # A forget that committed first is re-read here and drops out of the count.
  def hold_live_accounts
    TenantUser.where(tenant_id: ActsAsTenant.current_tenant.id).order(:id).lock("FOR SHARE").pluck(:id)
  end

  # A release before this stream, still serving during a deploy, writes only
  # the flag. Record what the flag says first, as reconcile would, so the
  # command acts on the grant the account holds rather than a stale stream.
  def settle(grants, grant, tenant_user_id, person_id, effective_on)
    AccountGrants::Aggregate::EVENTS.fetch(grant)
    flagged = TenantUser.where(id: tenant_user_id).pick(grant)
    return if flagged.nil? || flagged == grants.holds?(grant, tenant_user_id)

    date = effective_on || today
    if flagged
      grants.add(grant, tenant_user_id:, person_id:, effective_on: date, already_held: true)
    else
      grants.remove(grant, tenant_user_id:, person_id:, effective_on: date)
    end
  end

  def today
    ActsAsTenant.current_tenant.today
  end
end
