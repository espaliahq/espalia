# frozen_string_literal: true

# What an HRIS field would give if a level or a fact came from it (#107). A
# read: it asks the HRIS for that one field and writes nothing.
#
# The payload holds counts and the units' labels, never a person, since a
# preview is about the field.
class Operations::Integrations::HrisFieldPreview < Operations::Base
  description "Preview what an HRIS field would give before choosing it as the source of an Org Graph " \
              "level or fact. For target \"level\": the units it would create, with their labels and how " \
              "many people fall in each, largest first. For a fact (\"cost_centre\", \"country\"): how many " \
              "people have a value and how many would change from what the Org Graph holds now. Both count " \
              "people the field is blank for and people whose record withholds it. Reads the HRIS live; " \
              "writes nothing."
  category :read
  approval :none

  parameter :field_id, String, required: true, allow_blank: false
  parameter :target, String, required: true, allowed: Integrations::HrisFieldPreview::TARGETS

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash]
  # @raise [Operations::Base::ParameterError] when no HRIS is connected, its
  #   catalogue holds no such field, or it refuses or limits the read
  def perform
    tenant = ActsAsTenant.current_tenant
    raise ParameterError, "No HRIS is connected" unless tenant.hris_config.connected?(tenant)

    payload(Integrations::HrisFieldPreview.new(tenant, field_id: params[:field_id], target: params[:target]).call)
  rescue Integrations::HrisFieldPreview::UnknownField => e
    raise ParameterError, e.message
  rescue Hris::Hibob::Errors::AuthenticationError
    raise ParameterError, "The HRIS refused the stored credentials."
  rescue Hris::Hibob::Errors::RateLimitError
    raise ParameterError, "The HRIS is limiting requests just now. Try again in a minute."
  end

  private

  def payload(preview)
    counts = preview.to_h.except(:field, :units)
    counts[:units] = preview.units.map(&:to_h) if preview.is_a?(Integrations::HrisFieldPreview::Level)
    { field: { id: preview.field.id, name: preview.field.name, kind: preview.field.kind.to_s }, target: params[:target], **counts }
  end
end
