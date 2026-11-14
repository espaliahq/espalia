# frozen_string_literal: true

require "aggregate_root"

# Configures RailsEventStore with:
# - ActiveRecord-backed PostgreSQL repository
# - JSON serialization, with shreddable fields encrypted (Shreddable::Mapper)
# - ComposedDispatcher: sync handlers (same transaction) + async handlers (SolidQueue)
#
# Access via: Rails.configuration.event_store
#
Rails.configuration.to_prepare do
  event_store = RailsEventStore::JSONClient.new(
    mapper: Shreddable::Mapper.new(Shreddable::Mapper.json_client_default),
    repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: JSON),
    message_broker: RubyEventStore::Broker.new(
      subscriptions: RubyEventStore::Subscriptions.new,
      dispatcher: RubyEventStore::ComposedDispatcher.new(
        RailsEventStore::AfterCommitDispatcher.new(
          scheduler: RailsEventStore::ActiveJobScheduler.new(serializer: JSON)
        ),
        RubyEventStore::SyncScheduler.new
      )
    ),
  )

  # Publish the store before subscribing. Async handlers `prepend
  # RailsEventStore::AsyncHandler`, whose load-time hook reads
  # `Rails.configuration.event_store` — so it must be set before the
  # subscribe lines autoload those handler classes.
  Rails.configuration.event_store = event_store

  # ── Synchronous projections (same transaction) ──
  event_store.subscribe(
    Frameworks::Projections::PublishedState.new,
    to: Frameworks::Projections::PublishedState.handled_events
  )

  event_store.subscribe(
    Frameworks::Projections::SuggestionThread.new,
    to: Frameworks::Projections::SuggestionThread.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::Projections::CurrentAssessment.new,
    to: PersonDevelopment::Projections::CurrentAssessment.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::Projections::EvidenceCollection.new,
    to: PersonDevelopment::Projections::EvidenceCollection.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::Projections::EvidenceRequests.new,
    to: PersonDevelopment::Projections::EvidenceRequests.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::Projections::CommentThread.new,
    to: PersonDevelopment::Projections::CommentThread.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::Projections::AssessmentAuthority.new,
    to: PersonDevelopment::Projections::AssessmentAuthority.handled_events
  )

  event_store.subscribe(
    AssessmentCycles::Projections::CurrentState.new,
    to: AssessmentCycles::Projections::CurrentState.handled_events
  )

  event_store.subscribe(
    AssessmentCycles::Projections::CalibrationSessions.new,
    to: AssessmentCycles::Projections::CalibrationSessions.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::Structure.new,
    to: OrgGraph::Projections::Structure.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::Members.new,
    to: OrgGraph::Projections::Members.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::PeopleColumns.new,
    to: OrgGraph::Projections::PeopleColumns.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::FactAges.new,
    to: OrgGraph::Projections::FactAges.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::UnitActivity.new,
    to: OrgGraph::Projections::UnitActivity.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::Leavers.new,
    to: OrgGraph::Projections::Leavers.handled_events
  )

  event_store.subscribe(
    OrgGraph::Projections::History.new,
    to: OrgGraph::Projections::History.handled_events
  )

  event_store.subscribe(
    TeamPlanning::Projections::Plans.new,
    to: TeamPlanning::Projections::Plans.handled_events
  )

  event_store.subscribe(
    TeamPlanning::Projections::PlanMembers.new,
    to: TeamPlanning::Projections::PlanMembers.handled_events
  )

  event_store.subscribe(
    TeamPlanning::Projections::Scenarios.new,
    to: TeamPlanning::Projections::Scenarios.handled_events
  )

  # ── Synchronous cross-stream sync handlers ──
  # NOTE: PersonEnrollmentSync dispatches PersonDevelopment commands,
  # so it MUST NOT be registered as a projection — running it twice
  # would raise "already in a cycle" from the PersonDev aggregate.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::PersonEnrollmentSync.new,
    to: AssessmentCycles::SyncHandlers::PersonEnrollmentSync.handled_events
  )

  # AutoEnrollNewAssignments dispatches the AssessmentCycles enroll command
  # (which then cascades via PersonEnrollmentSync to PersonDev). Same
  # projection-rebuild hazard as above — MUST NOT be registered as a projection.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments.new,
    to: AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments.handled_events
  )

  # FeedbackExchange::AssignmentRetry enqueues a feedback exchange sync when a
  # newly assigned person has peer feedback waiting for an assignment. It
  # starts jobs — MUST NOT be registered as a projection.
  event_store.subscribe(
    FeedbackExchange::AssignmentRetry.new,
    to: FeedbackExchange::AssignmentRetry.handled_events
  )

  # FrameworkVersionMigrationSync dispatches PersonDevelopment commands
  # per affected person whenever a framework version publishes. Same
  # projection-rebuild hazard — MUST NOT be registered as a projection.
  # Subscribed AFTER PublishedState so it reads the freshly-rebuilt
  # FrameworkState::Capability rows (with the new survivors).
  event_store.subscribe(
    Frameworks::SyncHandlers::FrameworkVersionMigrationSync.new,
    to: Frameworks::SyncHandlers::FrameworkVersionMigrationSync.handled_events
  )

  # FrameworkVersionRollSync advances the upper-bound framework version
  # on every open AssessmentCycle scoped to the framework. Same
  # projection-rebuild hazard — MUST NOT be registered as a projection.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::FrameworkVersionRollSync.new,
    to: AssessmentCycles::SyncHandlers::FrameworkVersionRollSync.handled_events
  )

  # ParticipantRoleSync re-snapshots an open cycle's per-participant assessed
  # role/level when the person is promoted/transferred mid-cycle. Dispatches
  # an AssessmentCycles command — same projection-rebuild hazard, MUST NOT be
  # registered as a projection.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::ParticipantRoleSync.new,
    to: AssessmentCycles::SyncHandlers::ParticipantRoleSync.handled_events
  )

  # CalibrationSessionCloseSync closes a cycle's not-yet-closed calibration
  # sessions when the cycle closes. Dispatches CalibrationSession commands —
  # same projection-rebuild hazard, MUST NOT be registered as a projection.
  # Subscribed AFTER CalibrationSessions (the projection) so it reads
  # fresh session rows.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::CalibrationSessionCloseSync.new,
    to: AssessmentCycles::SyncHandlers::CalibrationSessionCloseSync.handled_events
  )

  # CalibrationRevisitSync mirrors a session's rating-revisit request onto the
  # person's PD stream. Dispatches PersonDevelopment commands — same
  # projection-rebuild hazard, MUST NOT be registered as a projection.
  event_store.subscribe(
    AssessmentCycles::SyncHandlers::CalibrationRevisitSync.new,
    to: AssessmentCycles::SyncHandlers::CalibrationRevisitSync.handled_events
  )

  # RetiredUnitMemberships ends or moves each membership of a retired unit in
  # the members' person streams. Dispatches OrgGraph person commands — same
  # projection-rebuild hazard, MUST NOT be registered as a projection.
  # Subscribed AFTER Members (the projection) so it reads current rows.
  event_store.subscribe(
    OrgGraph::SyncHandlers::RetiredUnitMemberships.new,
    to: OrgGraph::SyncHandlers::RetiredUnitMemberships.handled_events
  )

  # LeaverMemberships ends a leaver's memberships in their own stream.
  # Dispatches OrgGraph person commands, so it MUST NOT be registered as a
  # projection.
  event_store.subscribe(
    OrgGraph::SyncHandlers::LeaverMemberships.new,
    to: OrgGraph::SyncHandlers::LeaverMemberships.handled_events
  )

  # PersonDevelopmentFeed reconciles a fed tenant's Person Development
  # streams from the Org Graph. Dispatches Person Development and cycle
  # commands, so it MUST NOT be registered as a projection.
  event_store.subscribe(
    OrgGraph::SyncHandlers::PersonDevelopmentFeed.new,
    to: OrgGraph::SyncHandlers::PersonDevelopmentFeed.handled_events
  )

  # ── Async handlers (via SolidQueue) ──
  # Side-effect handlers (notifications). NOT projections — never register
  # these in Projections::Registry (replaying would re-send notifications).
  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::EvidenceRequestNotifier,
    to: PersonDevelopment::AsyncHandlers::EvidenceRequestNotifier.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::CommentNotifier,
    to: PersonDevelopment::AsyncHandlers::CommentNotifier.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::FeedbackNotifier,
    to: PersonDevelopment::AsyncHandlers::FeedbackNotifier.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::RatingRevisitNotifier,
    to: PersonDevelopment::AsyncHandlers::RatingRevisitNotifier.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::LensAlignmentNotifier,
    to: PersonDevelopment::AsyncHandlers::LensAlignmentNotifier.handled_events
  )

  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::ExplorationNotifier,
    to: PersonDevelopment::AsyncHandlers::ExplorationNotifier.handled_events
  )

  # Asks the model where new or edited feedback belongs (behind the tenant's
  # evidence_suggestions_enabled switch). Calls an outside service, so it
  # MUST NOT be registered as a projection.
  event_store.subscribe(
    PersonDevelopment::AsyncHandlers::PlacementSuggester,
    to: PersonDevelopment::AsyncHandlers::PlacementSuggester.handled_events
  )
end
