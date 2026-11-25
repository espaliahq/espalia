# frozen_string_literal: true

# Writes planning inputs as the tenant's tools do, through the
# TenantPlanningInputs stream, so a pay band takes its place in the list.
module PlanningInputsHelpers
  # @param attributes [Hash] as PayBand.new takes them
  # @return [PayBand]
  def add_pay_band!(**attributes) = add_planning_input!(:pay_bands, **attributes)

  # @param table [Symbol] one of TenantPlanningInputs::Rows::TABLES
  # @param changed_by_id [String, nil] the person who makes the change
  # @param attributes [Hash] as the table's model takes them; an `updated_by:` account names its person as the editor
  # @return [ApplicationRecord] the row as the table now holds it
  def add_planning_input!(table, changed_by_id: nil, **attributes)
    if (account = attributes.delete(:updated_by))
      changed_by_id ||= TenantUser.where(tenant_id: ActsAsTenant.current_tenant.id, user_id: account.id).pick(:person_id)
    end
    save_planning_input!(table, TenantPlanningInputs::Rows.model(table).new(**attributes), changed_by_id:)
  end

  # @param table [Symbol]
  # @param record [ApplicationRecord] new or loaded, with the change set and unsaved
  # @return [ApplicationRecord] the row as the table now holds it
  def save_planning_input!(table, record, changed_by_id: nil)
    TenantPlanningInputs::CommandHandler.new.save(table, changed_by_id:) { record }
  end

  # @param records [Array<ApplicationRecord>] rows of one table
  def remove_planning_inputs!(*records, changed_by_id: nil)
    records.each do |record|
      TenantPlanningInputs::CommandHandler.new.remove(TenantPlanningInputs::Rows::TABLES.key(record.class.name), record.id, changed_by_id:)
    end
  end

  # @param ids [Array<String>] every band id once, position 1 first
  def reorder_pay_bands!(ids, from: nil, changed_by_id: nil)
    TenantPlanningInputs::CommandHandler.new.reorder_bands(ids, from:, changed_by_id:)
  end
end
