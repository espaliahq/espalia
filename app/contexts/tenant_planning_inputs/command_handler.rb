# frozen_string_literal: true

# Handles commands for a tenant's planning inputs.
#
# Every command takes the `pay_bands:<tenant>` lock, then the stream's, in
# that order, as the previous release takes the first. Under both it catches
# up with what the tables hold, so a row the previous release wrote during a
# deploy is in the stream before the command decides.
#
class TenantPlanningInputs::CommandHandler
  # @param repository [TenantPlanningInputs::Repository]
  def initialize(repository: TenantPlanningInputs::Repository.new)
    @repository = repository
  end

  # Writes the row the block returns, once its model's validations pass. The
  # block runs under the locks, so it reads the row as it stands.
  #
  # @param table [Symbol] one of {TenantPlanningInputs::Rows::TABLES}
  # @param changed_by_id [String, nil] person_id of the actor
  # @yieldreturn [ApplicationRecord] the row, new or loaded, with the change set and unsaved
  # @return [ApplicationRecord] the row as the table now holds it
  # @raise [ActiveRecord::RecordInvalid] when the row fails its validations
  # @raise [TenantPlanningInputs::Refused] when another row rules it out, or a loaded row is gone
  def save(table, changed_by_id:)
    id = nil
    locked do |inputs|
      record = yield
      inputs.held!(table, record.id) if record.persisted?
      raise ActiveRecord::RecordInvalid, record unless record.valid?

      id = record.id || SecureRandom.uuid_v7
      inputs.set(table, id:, row: TenantPlanningInputs::Rows.dump(table, record), at: now, changed_by_id:)
    end
    TenantPlanningInputs::Rows.model(table).find(id)
  end

  # @param table [Symbol] any but :reference_currencies
  # @param id [String]
  # @param changed_by_id [String, nil]
  # @raise [TenantPlanningInputs::Refused] when the tenant has no such row
  def remove(table, id, changed_by_id:)
    locked { it.remove(table, id:, at: now, changed_by_id:) }
  end

  # @param ids [Array<String>] every band id once, position 1 first
  # @param from [Array<String>, nil] the order the caller read
  # @param changed_by_id [String, nil]
  # @raise [TenantPlanningInputs::Refused] unless ids are every band once, in a list that hasn't moved since from
  def reorder_bands(ids, from:, changed_by_id:)
    locked { it.reorder_bands(ids, from:, at: now, changed_by_id:) }
  end

  private

  def locked
    tenant = ActsAsTenant.current_tenant or raise ArgumentError, "No tenant context available"
    PayBand.with_list_lock(tenant.id) do
      @repository.with_aggregate do |inputs|
        TenantPlanningInputs::Reconciliation.new(tenant, repository: @repository).catch_up(inputs)
        yield inputs
      end
    end
  end

  def now = TenantPlanningInputs::Rows.time(Time.current)
end
