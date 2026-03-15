# frozen_string_literal: true

# Synchronous projection that materialises published framework state.
#
# Subscribes to Framework aggregate events and maintains the
# {FrameworkState::Framework} read model. Runs in the same transaction
# as the event publish.
#
class Frameworks::Projections::PublishedState
  # @param event [RubyEventStore::Event]
  def call(event)
    case event
    when Frameworks::Events::FrameworkCreated
      handle_framework_created(event)
    end
  end

  private

  def handle_framework_created(event)
    with_tenant(event) do
      FrameworkState::Framework.create!(
        framework_id: event.data[:framework_id],
        name: event.data[:name]
      )
    end
  end

  # Sets tenant context from event metadata for projection writes.
  #
  # @param event [RubyEventStore::Event]
  # @yield block to execute within tenant context
  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
