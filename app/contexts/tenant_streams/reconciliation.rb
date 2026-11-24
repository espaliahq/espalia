# frozen_string_literal: true

# Records whatever a table holds that its tenant stream doesn't: the table is
# the truth.
#
# An entry in the table and not the stream becomes an `already_held` event,
# and an entry in the stream and not the table becomes a removal. Neither
# names an actor. An entry whose row was forgotten is left as it is. Writing
# only what differs makes a second run write nothing, so predeploy can run
# it before and after the rebuild.
#
# A subclass names its repository and answers five questions: what the
# table holds, what the stream holds, which entries were forgotten, and how
# to record an addition and a removal. Entries are keyed the same way on
# both sides.
#
# @example
#   AccountGrants::Reconciliation.new(tenant).call
#   # => #<data Report added=1, removed=0>
class TenantStreams::Reconciliation
  # What a run recorded.
  Report = Data.define(:added, :removed)

  # @param tenant [Tenant]
  # @param repository [TenantStreams::Repository]
  def initialize(tenant, repository: self.class.repository)
    @tenant = tenant
    @repository = repository
  end

  # @return [TenantStreams::Repository] the repository for the stream reconciled
  def self.repository
    raise NotImplementedError, "#{self} must define .repository"
  end

  # @return [Report]
  def call
    ActsAsTenant.with_tenant(@tenant) do
      report = nil
      @repository.with_aggregate { |aggregate| report = reconcile(aggregate) }
      report
    end
  end

  # Records the differences on an aggregate the caller already holds under
  # its stream's lock, as a command does before acting on what the table says.
  #
  # @param aggregate [AggregateRoot]
  # @return [Report]
  def reconcile(aggregate)
    table = held_in_table
    stream = held_in_stream(aggregate)
    missing = table.except(*stream.keys)
    cleared = stream.except(*table.keys)
    cleared = cleared.except(*forgotten(cleared.keys)) if cleared.any?

    missing.each { |key, row| record_held(aggregate, key, row) }
    cleared.each { |key, recorded| record_removed(aggregate, key, recorded) }
    Report.new(added: missing.size, removed: cleared.size)
  end

  private

  # @return [Hash{Object => Object}] each entry the table holds, keyed, with its row
  def held_in_table
    raise NotImplementedError, "#{self.class} must define #held_in_table"
  end

  # @return [Hash{Object => Object}] each entry the stream holds, keyed, with what it recorded
  def held_in_stream(aggregate)
    raise NotImplementedError, "#{self.class} must define #held_in_stream"
  end

  # @param keys [Array<Object>] entries the stream holds and the table doesn't
  # @return [Array<Object>] those whose row was forgotten, to leave alone
  def forgotten(keys)
    raise NotImplementedError, "#{self.class} must define #forgotten"
  end

  def record_held(aggregate, key, row)
    raise NotImplementedError, "#{self.class} must define #record_held"
  end

  def record_removed(aggregate, key, recorded)
    raise NotImplementedError, "#{self.class} must define #record_removed"
  end

  def today
    @today ||= @tenant.today
  end
end
