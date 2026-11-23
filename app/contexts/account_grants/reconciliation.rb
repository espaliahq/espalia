# frozen_string_literal: true

# Records whatever the tenant_users flags hold that the AccountGrants stream doesn't: the flag is the truth.
#
# A flag set with no grant recorded becomes an `already_held` addition, and
# a recorded grant whose flag is clear, or whose account was destroyed,
# becomes a removal. A forgotten account is left as it is. A flagged account
# with no person is recorded too, with no person, so a rebuild keeps its
# grant.
#
# @example
#   AccountGrants::Reconciliation.new(tenant).call
#   # => #<data Report added=1, removed=0>
class AccountGrants::Reconciliation < TenantStreams::Reconciliation
  # @return [AccountGrants::Repository]
  def self.repository = AccountGrants::Repository.new

  private

  def held_in_table
    accounts = TenantUser.where(tenant_id: @tenant.id).to_a
    AccountGrants::Aggregate::GRANTS.each_with_object({}) do |grant, held|
      accounts.each { |account| held[[ grant, account.id ]] = account if account.public_send(grant) }
    end
  end

  def held_in_stream(aggregate)
    AccountGrants::Aggregate::GRANTS.each_with_object({}) do |grant, held|
      aggregate.holders(grant).each { |id, person_id| held[[ grant, id ]] = person_id }
    end
  end

  def forgotten(keys)
    ids = TenantUser.unscoped.where(id: keys.map(&:last)).where.not(forgotten_at: nil).pluck(:id)
    keys.select { |_, id| ids.include?(id) }
  end

  def record_held(aggregate, (grant, _), account)
    aggregate.add(grant, tenant_user_id: account.id, person_id: account.person_id, effective_on: today, already_held: true)
  end

  def record_removed(aggregate, (grant, id), person_id)
    aggregate.remove(grant, tenant_user_id: id, person_id:, effective_on: today)
  end
end
