# frozen_string_literal: true

# Records whatever the five planning input tables hold that the
# TenantPlanningInputs stream doesn't: the table is the truth.
#
# A row in the table and not the stream becomes an `already_held` event with
# its own id, position and timestamps. A row the stream holds and the table
# doesn't becomes a removal. A row the table changed in place becomes a
# change, as the table holds it. A band recorded this way moves no other
# band: each band's position is recorded as the table holds it. None names
# an actor; each names who last changed the row, as `last_changed_by_id`.
# The rows name no person, so none is ever left alone as forgotten.
#
# @example
#   TenantPlanningInputs::Reconciliation.new(tenant).call
#   # => #<data Report added=3, removed=0, changed=0>
class TenantPlanningInputs::Reconciliation < TenantStreams::Reconciliation
  Rows = TenantPlanningInputs::Rows
  private_constant :Rows

  # @return [TenantPlanningInputs::Repository]
  def self.repository = TenantPlanningInputs::Repository.new

  private

  # Locks the rows it reads, so a change the previous release makes waits
  # for the run and is recorded by the next, never written over by this one.
  def held_in_table
    @legacy_editors = {}
    Rows::TABLES.each_key.with_object({}) do |table, held|
      rows = Rows.model(table).where(tenant_id: @tenant.id).lock
      rows.find_each { |record| held[[ table, record.id ]] = record }
      @legacy_editors.merge!(legacy_accounts(rows).transform_keys { [ table, it ] })
    end
  end

  # A release before a4 named the account that last changed a row in
  # `updated_by_id`, which the models now ignore; a4b drops it.
  def legacy_accounts(rows) = rows.where.not(updated_by_id: nil).pluck(:id, :updated_by_id).to_h

  def held_in_stream(aggregate)
    Rows::TABLES.each_key.with_object({}) do |table, held|
      aggregate.entries(table).each { |id, entry| held[[ table, id ]] = entry }
    end
  end

  def forgotten(_keys) = []

  # Both sides are read as the table types read them, so a figure the stream
  # holds as "120000.0" equals the table's 120000.00. A comparison of the raw
  # values would record a change on every run. A row that still names an
  # account counts as changed, so the projection clears it before a4b.
  def changed?(record, entry)
    table = table_of(record)
    Rows.cast(table, Rows.dump(table, record)) != Rows.cast(table, Rows.complete(table, entry.row)) ||
      Rows.time(record.updated_at) != entry.updated_at || @legacy_editors.key?([ table, record.id ])
  end

  def record_held(aggregate, (table, id), record)
    aggregate.record_held(table, id:, row: Rows.dump(table, record), created_at: Rows.time(record.created_at),
                                 **as_it_stands(table, record))
  end

  def record_changed(aggregate, (table, id), record, _entry)
    aggregate.record_changed(table, id:, row: Rows.dump(table, record), **as_it_stands(table, record))
  end

  def record_removed(aggregate, (table, id), _entry)
    aggregate.record_removed(table, id:, at: Rows.time(Time.current), **band_stamp(table))
  end

  def as_it_stands(table, record)
    { updated_at: Rows.time(record.updated_at), last_changed_by_id: editor(record), **band_stamp(table) }
  end

  # Only a release before a4 wrote `updated_by_id`, and the projection clears
  # it, so a row that still holds one was last changed through that release.
  def editor(record)
    account = @legacy_editors[[ table_of(record), record.id ]] or return record.updated_by_person_id

    TenantUser.where(tenant_id: @tenant.id, user_id: account, forgotten_at: nil).pick(:person_id)
  end

  def band_stamp(table)
    return {} unless table == :pay_bands

    stamp = Tenant.where(id: @tenant.id).pick(:pay_bands_changed_at)
    { bands_changed_at: stamp && Rows.time(stamp) }
  end

  def table_of(record) = Rows::TABLES.key(record.class.name)
end
