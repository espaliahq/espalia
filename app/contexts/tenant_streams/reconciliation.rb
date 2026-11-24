# frozen_string_literal: true

# Records whatever a table holds that its tenant stream doesn't: the table is
# the truth.
#
# An entry in the table and not the stream becomes an `already_held` event,
# and an entry in the stream and not the table becomes a removal. Neither
# names an actor. An entry whose row was forgotten is left as it is, never
# removed or changed; the table must not hold a forgotten row at all. Writing
# only what differs makes a second run write nothing, so predeploy can run
# it before and after the rebuild.
#
# A subclass names its repository and answers five questions: what the
# table holds, what the stream holds, which entries were forgotten, and how
# to record an addition and a removal. Entries are keyed the same way on
# both sides. A table whose rows change in place also says when an entry
# held on both sides differs, and how to record the change, again with no
# actor. Without that, an entry on both sides counts as equal.
#
# @example
#   AccountGrants::Reconciliation.new(tenant).call
#   # => #<data Report added=1, removed=0, changed=0>
class TenantStreams::Reconciliation
  # What a run recorded.
  Report = Data.define(:added, :removed, :changed) do
    # @return [Integer] every event the run recorded
    def recorded = added + removed + changed
  end

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

  private

  def reconcile(aggregate)
    table = held_in_table
    stream = held_in_stream(aggregate)
    missing = table.except(*stream.keys)
    cleared = stream.except(*table.keys)
    cleared = cleared.except(*forgotten(cleared.keys)) if cleared.any?

    differing = table.slice(*stream.keys).filter_map { |key, row| [ key, row, stream[key] ] if changed?(row, stream[key]) }
    if differing.any?
      left_alone = forgotten(differing.map(&:first)).to_set
      differing = differing.reject { |key, *| left_alone.include?(key) }
    end

    missing.each { |key, row| record_held(aggregate, key, row) }
    cleared.each { |key, recorded| record_removed(aggregate, key, recorded) }
    differing.each { |key, row, recorded| record_changed(aggregate, key, row, recorded) }
    Report.new(added: missing.size, removed: cleared.size, changed: differing.size)
  end

  # @return [Hash{Object => Object}] each entry the table holds, keyed, with its row
  def held_in_table
    raise NotImplementedError, "#{self.class} must define #held_in_table"
  end

  # @return [Hash{Object => Object}] each entry the stream holds, keyed, with what it recorded
  def held_in_stream(aggregate)
    raise NotImplementedError, "#{self.class} must define #held_in_stream"
  end

  # @param keys [Array<Object>] entries the stream holds that would be removed or changed
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

  # @param row [Object] what the table holds for an entry the stream also holds
  # @param recorded [Object] what the stream holds for it
  # @return [Boolean] whether to record the table's row as a change
  def changed?(row, recorded) = false

  # Called only for an entry {#changed?} says differs.
  def record_changed(aggregate, key, row, recorded)
    raise NotImplementedError, "#{self.class} must define #record_changed"
  end

  def today
    @today ||= @tenant.today
  end
end
