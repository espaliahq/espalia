# frozen_string_literal: true

# Synchronous projection that materialises per-level capability assessment ratings.
#
# Subscribes to PersonDevelopment aggregate events and upserts
# AssessmentLevelRating rows — one per (cycle_id, person, framework,
# capability_stable_id, level_ordinal). Runs in the same transaction
# as the event publish.
#
# Because rating rows are scoped by cycle, historical ratings across
# cycles are preserved rather than overwritten. This lets both
# "latest rating" and "rating in cycle X" queries be answered from
# the read model.
#
# Also mirrors per-person progress into {AssessmentCycleParticipant}:
# - First rating of any kind → `started_at`
# - Alignment event → `aligned_at` + `status = "aligned"`
#
class PersonDevelopment::Projections::CurrentAssessment
  # All event classes this projection handles.
  #
  # @return [Array<Class>] event classes
  def self.handled_events
    [
      PersonDevelopment::Events::PersonAssignedToFramework,
      PersonDevelopment::Events::PersonRoleChanged,
      PersonDevelopment::Events::PersonLevelChanged,
      PersonDevelopment::Events::JoinedAssessmentCycle,
      PersonDevelopment::Events::LeftAssessmentCycle,
      PersonDevelopment::Events::SelfRated,
      PersonDevelopment::Events::SelfRatingRevised,
      PersonDevelopment::Events::SelfRatingCleared,
      PersonDevelopment::Events::ManagerRated,
      PersonDevelopment::Events::ManagerRatingRevised,
      PersonDevelopment::Events::ManagerRatingCleared,
      PersonDevelopment::Events::AlignmentStarted,
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
    when PersonDevelopment::Events::PersonRoleChanged then handle_role_changed(event)
    when PersonDevelopment::Events::PersonLevelChanged then handle_level_changed(event)
    when PersonDevelopment::Events::JoinedAssessmentCycle then handle_joined_cycle(event)
    when PersonDevelopment::Events::LeftAssessmentCycle then handle_left_cycle(event)
    when PersonDevelopment::Events::SelfRated then handle_self_rated(event)
    when PersonDevelopment::Events::SelfRatingRevised then handle_self_rating_revised(event)
    when PersonDevelopment::Events::SelfRatingCleared then handle_self_rating_cleared(event)
    when PersonDevelopment::Events::ManagerRated then handle_manager_rated(event)
    when PersonDevelopment::Events::ManagerRatingRevised then handle_manager_rating_revised(event)
    when PersonDevelopment::Events::ManagerRatingCleared then handle_manager_rating_cleared(event)
    when PersonDevelopment::Events::AlignmentStarted then handle_alignment_started(event)
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

  def handle_role_changed(event)
    assignment = find_assignment(event)
    return unless assignment

    assignment.update!(
      role_id: event.data[:new_role_id],
      level_id: event.data[:new_level_id]
    )
  end

  def handle_level_changed(event)
    assignment = find_assignment(event)
    return unless assignment

    assignment.update!(level_id: event.data[:new_level_id])
  end

  # Join/leave events are informational on the PersonDev stream — the
  # authoritative participant row is maintained by
  # {AssessmentCycles::Projections::CurrentState} via its own event
  # subscriptions. These handlers intentionally do not write to any
  # read model.
  def handle_joined_cycle(_event)
    # no-op
  end

  def handle_left_cycle(_event)
    # no-op
  end

  def handle_self_rated(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
    touch_participant_started(event)
    broadcast_assessment_sync(event)
  end

  def handle_self_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = event.data[:frequency]
    rating.self_rated_comment = event.data[:comment]
    rating.last_self_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
    touch_participant_started(event)
    broadcast_assessment_sync(event)
  end

  def handle_self_rating_cleared(event)
    rating = find_or_init_rating(event)
    rating.self_rated_frequency = nil
    rating.self_rated_comment = nil
    rating.save!
    broadcast_assessment_sync(event)
  end

  def handle_manager_rated(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
    touch_participant_started(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rating_revised(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = event.data[:frequency]
    rating.manager_rated_comment = event.data[:comment]
    rating.last_manager_rated_at = event.metadata[:timestamp] || Time.current
    rating.save!
    touch_participant_started(event)
    broadcast_assessment_sync(event)
  end

  def handle_manager_rating_cleared(event)
    rating = find_or_init_rating(event)
    rating.manager_rated_frequency = nil
    rating.manager_rated_comment = nil
    rating.save!
    broadcast_assessment_sync(event)
  end

  def handle_alignment_started(event)
    participant = AssessmentCycleParticipant.find_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id]
    )
    return unless participant

    now = event.metadata[:timestamp] || Time.current
    participant.update!(
      status: "aligning",
      alignment_started_at: now,
      alignment_started_by_id: event.data[:started_by_id],
      started_at: participant.started_at || now
    )
    broadcast_assessment_sync(event)
  end

  def handle_assessment_aligned(event)
    rating = find_or_init_rating(event)
    rating.aligned_frequency = event.data[:aligned_frequency]
    rating.aligned_comment = event.data[:comment]
    rating.last_aligned_at = event.metadata[:timestamp] || Time.current
    rating.save!
    broadcast_assessment_sync(event)
  end

  # Finds or initialises an AssessmentLevelRating for the (cycle, person,
  # framework, capability_stable_id, level_ordinal) composite key.
  #
  # @param event [RubyEventStore::Event]
  # @return [AssessmentLevelRating]
  def find_or_init_rating(event)
    AssessmentLevelRating.find_or_initialize_by(
      cycle_id: event.data[:cycle_id],
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

  # Sets the participant's started_at if not already set.
  #
  # @param event [RubyEventStore::Event] a rating event carrying cycle_id
  def touch_participant_started(event)
    participant = AssessmentCycleParticipant.find_by(
      cycle_id: event.data[:cycle_id],
      person_id: event.metadata[:person_id]
    )
    return unless participant
    return if participant.started_at.present?

    now = event.metadata[:timestamp] || Time.current
    participant.update_columns(
      started_at: now,
      status: "started",
      updated_at: now
    )
  end

  # Broadcasts a sync signal to all viewers of this assessment.
  # The signal triggers a matrix frame reload via the matrix Stimulus controller.
  #
  # @param event [RubyEventStore::Event]
  def broadcast_assessment_sync(event)
    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    # Don't let broadcast failures break the projection
    Rails.logger.warn("[CurrentAssessment] Broadcast failed: #{e.message}")
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
