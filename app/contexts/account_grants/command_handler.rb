# frozen_string_literal: true

# Handles commands for a tenant's account grants.
#
# Each command names the account and the grant; the date is today in the
# tenant's time zone unless the caller gives one.
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
      grants.remove(grant, tenant_user_id:, person_id:, effective_on: effective_on || today, removed_by_id:)
    end
  end

  private

  def today
    ActsAsTenant.current_tenant.today
  end
end
