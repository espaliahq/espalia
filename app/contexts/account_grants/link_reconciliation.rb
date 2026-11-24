# frozen_string_literal: true

# Records whatever link `tenant_users.person_id` holds that the
# TenantAccountGrants stream doesn't: the column is the truth.
#
# A live account linked in the table and not the stream, or to another
# person, becomes an `already_held` AccountLinkedToPerson, after an unlink of
# the old person. A link the stream records and the table no longer holds
# becomes an AccountUnlinkedFromPerson: `forgotten` when the person or the
# account was forgotten, `account_removed` when the row is gone, and
# `cleared` otherwise. The release before this one erases a forgotten
# person's link with no event, and this records it.
#
# A person linked to more than one account is logged: the stream records
# such links as held, but refuses a new one.
#
# @example
#   AccountGrants::LinkReconciliation.new(tenant).call
#   # => #<data Report added=1, removed=0, changed=0>
class AccountGrants::LinkReconciliation < TenantStreams::Reconciliation
  # @return [AccountGrants::Repository]
  def self.repository = AccountGrants::Repository.new

  # @param aggregate [AccountGrants::Aggregate]
  # @return [TenantStreams::Reconciliation::Report]
  def reconcile(aggregate)
    report = super
    aggregate.shared_people.each do |person_id, accounts|
      Rails.logger.warn("[account_links] tenant=#{@tenant.id} person=#{person_id} is linked to #{accounts.size} accounts")
    end
    report
  end

  private

  def held_in_table
    @held_in_table ||= TenantUser.where(tenant_id: @tenant.id, forgotten_at: nil).where.not(person_id: nil).index_by(&:id)
  end

  def held_in_stream(aggregate) = aggregate.links

  def forgotten(_keys) = []

  def record_held(aggregate, id, account)
    aggregate.link_account(tenant_user_id: id, person_id: account.person_id, effective_on: today, already_held: true)
  end

  def record_removed(aggregate, id, person_id)
    aggregate.unlink_account(tenant_user_id: id, effective_on: today, reason: unlink_reason(id, person_id))
  end

  def changed?(account, person_id) = account.person_id != person_id

  def record_changed(aggregate, id, account, _person_id)
    aggregate.unlink_account(tenant_user_id: id, effective_on: today, reason: :cleared)
    record_held(aggregate, id, account)
  end

  def unlink_reason(id, person_id)
    account = TenantUser.unscoped.find_by(id:)
    return :account_removed if account.nil?
    return :forgotten if account.forgotten_at || Person.unscoped.where(id: person_id).where.not(forgotten_at: nil).exists?

    :cleared
  end
end
