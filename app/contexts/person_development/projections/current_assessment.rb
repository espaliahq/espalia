# frozen_string_literal: true

# Synchronous projection that materialises per-level capability assessment ratings.
#
# Subscribes to PersonDevelopment aggregate events and upserts
# AssessmentLevelRating rows — one per (person, framework, capability_stable_id,
# level_ordinal). Runs in the same transaction as the event publish.
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
      PersonDevelopment::Events::SelfRatingRevised,
      PersonDevelopment::Events::SelfRatingCleared,
      PersonDevelopment::Events::ManagerRated,
      PersonDevelopment::Events::AssessmentAligned
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
    when PersonDevelopment::Events::PersonAssignedToFramework then handle_assigned(event)
    when PersonDevelopment::Events::AssessmentCycleOpened then handle_cycle_opened(event)
    when PersonDevelopment::Events::AssessmentCycleCompleted then handle_cycle_completed(event)
    when PersonDevelopment::Events::SelfRated then handle_self_rated(event)
    when PersonDevelopment::Events::SelfRatingRevised then handle_self_rating_revised(event)
    when PersonDevelopment::Events::SelfRatingCleared then handle_self_rating_cleared(event)
    when PersonDevelopment::Events::ManagerRated then handle_manager_rated(event)
    when PersonDevelopment::Events::AssessmentAligned then handle_assessment_aligned(event)
    end
  end

  def handle_assigned(event)
    PersonFrameworkAssignment.find_or_initialize_by(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id]
    ).tap do |assignment|
      assignment.role_id = event.data[:role_id]
      assignment.level_id = event.data[:level_id]
      assignment.save!
    end
  end

  def handle_cycle_opened(event)
    assignment = find_assignment(event)
    return unless assignment

    assignment.update!(
      current_cycle_id: event.data[:cycle_id],
      cycle_status: "open",
      cycle_name: event.data[:cycle_name]
    )
  end

  def handle_cycle_completed(event)
    assignment = find_assignment(event)
    return unless assignment

    assignment.update!(cycle_status: "completed")
  end

  def handle_self_rated(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
  end

  def handle_self_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
  end

  def handle_self_rating_cleared(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = nil
    rating.self_rated_comment = nil
    rating.save!
  end

  def handle_manager_rated(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
  end

  def handle_assessment_aligned(event)
    rating = find_or_init_rating(event)
    rating.aligned_frequency = event.data[:aligned_frequency]
    rating.aligned_comment = event.data[:comment]
    rating.last_aligned_at = event.metadata[:timestamp] || Time.current
    rating.save!
  end

  # Finds or initialises an AssessmentLevelRating for the (person, framework,
  # capability_stable_id, level_ordinal) composite key.
  #
  # @param event [RubyEventStore::Event]
  # @return [AssessmentLevelRating]
  def find_or_init_rating(event)
    AssessmentLevelRating.find_or_initialize_by(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal]
    )
  end

  # Finds the PersonFrameworkAssignment for the event's person and framework.
  #
  # @param event [RubyEventStore::Event]
  # @return [PersonFrameworkAssignment, nil]
  def find_assignment(event)
    PersonFrameworkAssignment.find_by(
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id]
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
