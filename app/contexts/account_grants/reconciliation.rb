# frozen_string_literal: true

# Records whatever the tenant_users flags hold that the AccountGrants stream doesn't: the flag is the truth.
#
# A flag set with no grant recorded becomes an `already_held` addition, and
# a recorded grant whose flag is clear, or whose account was destroyed,
# becomes a removal. Neither names an actor. A forgotten account is left as
# it is, and a flagged account with no person is skipped and reported.
# Writing only what differs makes a second run write nothing.
#
# @example
#   AccountGrants::Reconciliation.new(tenant).call
#   # => #<data Report added=1, removed=0, skipped_ids=[]>
class AccountGrants::Reconciliation
  # What a run recorded, and the flagged accounts it could not.
  Report = Data.define(:added, :removed, :skipped_ids)

  # @param tenant [Tenant]
  # @param repository [AccountGrants::Repository]
  def initialize(tenant, repository: AccountGrants::Repository.new)
    @tenant = tenant
    @repository = repository
  end

  # @return [Report]
  def call
    ActsAsTenant.with_tenant(@tenant) do
      added = removed = 0
      skipped_ids = []
      @repository.with_grants do |aggregate|
        accounts = TenantUser.where(tenant_id: @tenant.id).to_a.index_by(&:id)
        AccountGrants::Aggregate::GRANTS.each do |grant|
          flagged, unlinked = accounts.values.select { it.public_send(grant) }.partition(&:person_id)
          skipped_ids |= unlinked.map(&:id)
          added += record_held(aggregate, grant, flagged)
          removed += record_cleared(aggregate, grant, accounts)
        end
      end
      Report.new(added:, removed:, skipped_ids:)
    end
  end

  private

  def record_held(aggregate, grant, flagged)
    missing = flagged.reject { aggregate.holds?(grant, it.id) }
    missing.each do |account|
      aggregate.add(grant, tenant_user_id: account.id, person_id: account.person_id, effective_on: today, already_held: true)
    end
    missing.size
  end

  def record_cleared(aggregate, grant, accounts)
    holders = aggregate.holders(grant).dup
    forgotten = TenantUser.unscoped.where(id: holders.keys).where.not(forgotten_at: nil).pluck(:id)
    cleared = holders.reject { |id, _| forgotten.include?(id) || accounts[id]&.public_send(grant) }
    cleared.each { |id, person_id| aggregate.remove(grant, tenant_user_id: id, person_id:, effective_on: today) }
    cleared.size
  end

  def today
    @today ||= @tenant.today
  end
end
