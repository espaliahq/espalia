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
    when PersonDevelopment::Events::SelfRated then handle_self_rated(event)
    when PersonDevelopment::Events::SelfRatingRevised then handle_self_rating_revised(event)
    when PersonDevelopment::Events::ManagerRated then handle_manager_rated(event)
    when PersonDevelopment::Events::AssessmentAligned then handle_assessment_aligned(event)
    end
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

  # Sets tenant context from event metadata for projection writes.
  #
  # @param event [RubyEventStore::Event]
  # @yield block to execute within tenant context
  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
