# frozen_string_literal: true

# Synchronous projection that materialises current assessment state.
#
# Subscribes to PersonDevelopment aggregate events and maintains
# the AssessmentState read model. Runs in the same transaction
# as the event publish.
#
class PersonDevelopment::Projections::CurrentAssessment
  # All event classes this projection handles.
  #
  # @return [Array<Class>] event classes
  def self.handled_events
    [
      PersonDevelopment::Events::PersonAssignedToFramework,
      PersonDevelopment::Events::AssessmentCycleOpened,
      PersonDevelopment::Events::AssessmentCycleCompleted,
      PersonDevelopment::Events::SelfRated,
      PersonDevelopment::Events::SelfRatingRevised
    ]
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
    end
  end

  private

  # Only SelfRated and SelfRatingRevised update the read model.
  # PersonAssignedToFramework, AssessmentCycleOpened, AssessmentCycleCompleted
  # are tracked in the aggregate state, not in the assessment read model.
  def handle(event)
    case event
    when PersonDevelopment::Events::SelfRated then handle_self_rated(event)
    when PersonDevelopment::Events::SelfRatingRevised then handle_self_rating_revised(event)
    end
  end

  def handle_self_rated(event)
    AssessmentState.find_or_initialize_by(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      capability_stable_id: event.data[:capability_stable_id]
    ).tap do |state|
      state.self_rated_level_id = event.data[:level_id]
      state.last_self_rated_at = event.metadata[:timestamp] || Time.current
      state.save!
    end
  end

  def handle_self_rating_revised(event)
    state = AssessmentState.find_by!(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      capability_stable_id: event.data[:capability_stable_id]
    )
    state.update!(
      self_rated_level_id: event.data[:new_level_id],
      last_self_rated_at: event.metadata[:timestamp] || Time.current
    )
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
