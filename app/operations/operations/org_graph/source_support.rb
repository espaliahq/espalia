# frozen_string_literal: true

# What the operations that set an Org Graph source share: which providers the
# tenant may choose, and turning the structure aggregate's refusals into
# parameter errors.
module Operations::OrgGraph::SourceSupport
  private

  # Espalia, or the HRIS the tenant has connected. A fact or level handed to
  # an HRIS nobody connected would never be read.
  def require_provider!(provider)
    return provider if provider == ::OrgGraph::StructureAggregate::ESPALIA

    tenant = ActsAsTenant.current_tenant
    return provider if tenant.hris_config.connected?(tenant) && tenant.hris_config.provider == provider

    raise Operations::Base::ParameterError, "provider: #{provider} is not connected; choose espalia or the connected HRIS"
  end

  def structure = ::OrgGraph::StructureCommandHandler.new(actor: context)

  # The structure aggregate refuses a change with an error that says why.
  def refusals
    yield
  rescue ArgumentError, RuntimeError => e
    raise Operations::Base::ParameterError, e.message
  end
end
