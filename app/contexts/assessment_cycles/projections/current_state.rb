# frozen_string_literal: true

# Synchronous projection that materialises assessment cycle state.
#
# Subscribes to AssessmentCycles aggregate events and maintains the
# `assessment_cycles` and `assessment_cycle_participants` read models.
# Runs in the same transaction as the event publish.
#
class AssessmentCycles::Projections::CurrentState
  # All event classes this projection handles.
  #
  # @return [Array<Class>]
  def self.handled_events
    [
      AssessmentCycles::Events::CycleDefined,
      AssessmentCycles::Events::PersonEnrolled,
      AssessmentCycles::Events::PersonUnenrolled,
      AssessmentCycles::Events::CycleClosed
    ]
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
    end
  end

  private

  def handle(event)
    case event
    when AssessmentCycles::Events::CycleDefined then handle_cycle_defined(event)
    when AssessmentCycles::Events::PersonEnrolled then handle_person_enrolled(event)
    when AssessmentCycles::Events::PersonUnenrolled then handle_person_unenrolled(event)
    when AssessmentCycles::Events::CycleClosed then handle_cycle_closed(event)
    end
  end

  def handle_cycle_defined(event)
    AssessmentCycle.create!(
      cycle_id: event.data[:cycle_id],
      framework_id: event.data[:framework_id],
      framework_version: event.data[:framework_version],
      name: event.data[:name],
      cycle_type: event.data[:cycle_type],
      status: "open",
      opened_at: event.metadata[:timestamp] || Time.current,
      defined_by: event.data[:defined_by]
    )
  end

  def handle_person_enrolled(event)
    AssessmentCycleParticipant.create!(
      cycle_id: event.data[:cycle_id],
      person_id: event.data[:person_id],
      status: "enrolled",
      enrolled_at: event.metadata[:timestamp] || Time.current
    )
  end

  def handle_person_unenrolled(event)
    participant = AssessmentCycleParticipant.find_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.data[:person_id]
    )
    return unless participant

    participant.update!(
      status: "withdrawn",
      withdrawn_at: event.metadata[:timestamp] || Time.current,
      withdrawal_reason: event.data[:reason]
    )
  end

  def handle_cycle_closed(event)
    cycle = AssessmentCycle.find_by(cycle_id: event.data[:cycle_id])
    return unless cycle

    closed_at = event.metadata[:timestamp] || Time.current
    cycle.update!(status: "closed", closed_at: closed_at)

    # Mark any still-enrolled participants as withdrawn with cycle_closed reason
    cycle.participants.where.not(status: "withdrawn").find_each do |participant|
      participant.update!(
        status: "withdrawn",
        withdrawn_at: closed_at,
        withdrawal_reason: "cycle_closed"
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
