# frozen_string_literal: true

# How the tenant's planning input tools write: through the tenant's planning
# inputs stream, with every refusal a parameter error that names what is
# wrong, never a figure.
module Operations::Tenants::PlanningInputWrites
  private

  # Writes the row the block builds, through the tenant's planning inputs
  # stream. The block runs under the stream's lock, so a row it loads is the
  # row as it stands.
  #
  # @param table [Symbol] one of {TenantPlanningInputs::Rows::TABLES}
  # @yieldreturn [ApplicationRecord] the row with the change set and unsaved
  # @return [ApplicationRecord] the row as the table now holds it
  # @raise [Operations::Base::ParameterError] naming what is wrong, never a figure or a rate
  def save_setting!(table, &)
    refusing_as_parameters { planning_inputs.save(table, changed_by_id: context.person&.id, &) }
  end

  # @return [TenantPlanningInputs::CommandHandler]
  def planning_inputs = TenantPlanningInputs::CommandHandler.new

  # @raise [Operations::Base::ParameterError] for a row the tenant's rules refuse
  def refusing_as_parameters
    yield
  rescue ActiveRecord::RecordInvalid => e
    raise Operations::Base::ParameterError, e.record.errors.full_messages.to_sentence
  rescue TenantPlanningInputs::Refused => e
    raise Operations::Base::ParameterError, e.message
  rescue ActiveRecord::RecordNotUnique
    raise Operations::Base::ParameterError, "Someone else set it at the same moment; try again"
  end
end
