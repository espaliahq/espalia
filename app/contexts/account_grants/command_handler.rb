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

  # Links an account to its person. Links the stream records to a destroyed
  # person, or held by a destroyed account, are unlinked first: destroying
  # either writes no event.
  #
  # @param account [TenantUser]
  # @param person [Person]
  # @param match [String, Symbol] one of {AccountGrants::Aggregate::MATCHES}
  # @param linked_by_id [String, nil] person_id of the actor
  # @return [AccountGrants::Aggregate]
  # @raise [AccountGrants::Aggregate::LinkTaken] when the account or the person is linked elsewhere
  # @raise [AccountGrants::Aggregate::PersonForgotten] when the person was forgotten
  def link_account(account, person, match:, linked_by_id: nil)
    ActiveRecord::Base.transaction do
      hold_person(person.id)
      @repository.with_grants do |grants|
        release_destroyed_links(grants, account.id, person.id)
        raise AccountGrants::Aggregate::PersonForgotten, "a forgotten person can't be linked" if forgotten?(person.id)

        grants.link_account(tenant_user_id: account.id, person_id: person.id, effective_on: today,
                            linked_by_id:, match: match.to_s)
      end
    end
  end

  # Unlinks every account linked to a person about to be forgotten, in the
  # table or the stream. A link only the table holds is recorded first, so
  # its unlink clears the column: erasure leaves no account naming them,
  # whatever wrote the link. Takes the grants lock, so the caller must hold
  # no tenant_users row yet. The accounts the table links to them are about
  # to be erased, so it refuses when they hold every admin the tenant has,
  # counted as {#set_role} counts them.
  #
  # @param person_id [String]
  # @return [Array<String>] the accounts the table linked to them, for the caller to erase
  # @raise [AccountGrants::Aggregate::LastAdmin] when erasing them would leave no admin
  def unlink_forgotten(person_id)
    linked = nil
    @repository.with_grants do |grants|
      hold_live_accounts
      AccountGrants::RoleReconciliation.new(ActsAsTenant.current_tenant, repository: @repository).reconcile(grants)
      linked = TenantUser.where(person_id:).order(:id).pluck(:id)
      grants.ensure_an_admin_outlives!(linked)
      ids = (linked | grants.accounts_of(person_id)).sort
      linked.each do |id|
        next if grants.person_of(id) == person_id

        grants.unlink_account(tenant_user_id: id, effective_on: today, reason: :cleared)
        grants.link_account(tenant_user_id: id, person_id:, effective_on: today, already_held: true)
      end
      ids.each { grants.unlink_account(tenant_user_id: it, effective_on: today, reason: :forgotten) }
    end
    linked
  end

  private

  # Lock order: the person's row, then the grants stream, then tenant_users
  # rows. A forget takes the person's row, then the grants lock in
  # {#unlink_forgotten}, and only then its tenant_users rows, so the two never
  # wait on each other in a cycle. A forget that committed first is re-read
  # here and drops out of the count. A link takes the person's row before
  # anything else, so it can't close a cycle with a forget. Only a release
  # older than b2 could: it held the account before waiting on the person.
  def hold_live_accounts
    TenantUser.where(tenant_id: ActsAsTenant.current_tenant.id).order(:id).lock("FOR SHARE").pluck(:id)
  end

  # The link's write to tenant_users.person_id takes this lock through the
  # foreign key. Taken before the grants lock, it waits for a forget holding
  # the row, rather than holding the grants lock the forget waits for.
  def hold_person(person_id)
    Person.unscoped.where(id: person_id).lock("FOR KEY SHARE").pick(:id)
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

  def release_destroyed_links(grants, tenant_user_id, person_id)
    recorded = grants.person_of(tenant_user_id)
    if recorded && !Person.unscoped.exists?(recorded)
      grants.unlink_account(tenant_user_id:, effective_on: today, reason: :cleared)
    end

    holders = grants.accounts_of(person_id)
    (holders - TenantUser.unscoped.where(id: holders).pluck(:id)).each { grants.unlink_account(tenant_user_id: it, effective_on: today, reason: :account_removed) }
  end

  def forgotten?(person_id) = Person.unscoped.where(id: person_id).where.not(forgotten_at: nil).exists?

  def today
    ActsAsTenant.current_tenant.today
  end
end
