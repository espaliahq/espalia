# frozen_string_literal: true

# Records whatever role `tenant_users.role` holds that the TenantAccountGrants stream doesn't: the column is the truth.
#
# A live account's role becomes an `already_held` AccountRoleSet when the
# stream records none or another one. An account the stream records that is
# no longer live, destroyed or forgotten, becomes an AccountRoleRemoved, so
# the last-admin check counts only accounts that can sign in. A forgotten
# account's row is left as it is.
#
# Predeploy runs it, and a role command runs it first under the same lock, so
# a role the previous release wrote straight to the column is never undone.
#
# @example
#   AccountGrants::RoleReconciliation.new(tenant).call
#   # => #<data Report added=1, removed=0>
class AccountGrants::RoleReconciliation < TenantStreams::Reconciliation
  # @return [AccountGrants::Repository]
  def self.repository = AccountGrants::Repository.new

  private

  def held_in_table
    @held_in_table ||= TenantUser.where(tenant_id: @tenant.id).to_h { [ [ it.id, it.role ], it ] }
  end

  # A live account whose role changed is recorded with its new role, which
  # replaces the old one, so the old one is no removal.
  def held_in_stream(aggregate)
    live = held_in_table.keys.to_h
    people = aggregate.role_holders
    aggregate.roles.filter_map { |id, role| [ [ id, role ], people[id] ] if live.fetch(id, role) == role }.to_h
  end

  def forgotten(_keys) = []

  def record_held(aggregate, _key, account)
    aggregate.set_role(tenant_user_id: account.id, person_id: account.person_id, role: account.role,
                       effective_on: today, already_held: true)
  end

  def record_removed(aggregate, (id, _role), person_id)
    aggregate.remove_role(tenant_user_id: id, person_id:, effective_on: today)
  end
end
