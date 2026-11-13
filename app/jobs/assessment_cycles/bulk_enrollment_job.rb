# frozen_string_literal: true

# Enrolls every currently-eligible person into an assessment cycle in the
# background. Bulk enrollment is far too heavy for a request: each person's
# enrollment replays their PersonDevelopment stream AND seeds carried-forward
# ratings from their prior cycle (potentially hundreds of events per person),
# so a real cohort reliably blows the HTTP timeout — the failure that
# motivated this job.
#
# Each person enrolls in their own transaction (mirroring the old inline
# loop): a domain failure on one person — e.g. a race with an admin enrolling
# them by hand — is counted and logged, never fatal to the rest. Re-running
# the job is safe: already-enrolled people are skipped by the aggregate and
# seeding is idempotent per side.
#
# Events carry `acting_via: "system"` provenance with the enrolling admin as
# `actor_id` (and as the domain-level `enrolled_by` on each event); the job id
# correlates everything one run produced.
class AssessmentCycles::BulkEnrollmentJob < ApplicationJob
  queue_as :default

  # @param cycle [AssessmentCycle] the open cycle to fill
  # @param enrolled_by [String, nil] person_id of the admin who requested it
  # @return [void]
  def perform(cycle, enrolled_by: nil)
    AuditMetadata.with(acting_via: :system, actor_id: enrolled_by, correlation_id: job_id) do
      ActsAsTenant.with_tenant(cycle.tenant) do
        enrolled = 0
        skipped = []
        command_handler = AssessmentCycles::CommandHandler.new

        cycle.eligible_people.find_each do |person|
          role_id, level_id = assignment_role_level(cycle, person.id)
          ActiveRecord::Base.transaction do
            # wrap_event_store is the bridge that stamps the thread-local
            # AuditMetadata onto RES event metadata — AuditMetadata.with
            # alone only sets the thread-local (see the reminder sweep job).
            AuditMetadata.wrap_event_store do
              command_handler.enroll(
                cycle.cycle_id, person.id, enrolled_by: enrolled_by,
                role_id: role_id, level_id: level_id
              )
            end
          end
          enrolled += 1
        rescue RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          skipped << person
          Rails.logger.warn(
            "[BulkEnrollment] cycle=#{cycle.cycle_id} person=#{person.id} skipped: #{e.message}"
          )
        end

        Rails.logger.info(
          "[BulkEnrollment] cycle=#{cycle.cycle_id} enrolled=#{enrolled} skipped=#{skipped.size}"
        )
        notify_outcome(cycle, enrolled_by, enrolled, skipped)
      end
    end
  end

  private

  # The enqueue-time flash only promises the eligible count; the outcome —
  # especially partial outcomes — must reach the admin, not just the logs.
  def notify_outcome(cycle, enrolled_by, enrolled, skipped)
    user = Person.find_by(id: enrolled_by)&.ensure_user!
    return if user.nil?

    BulkEnrollmentCompletedNotifier.with(
      tenant_id: cycle.tenant_id,
      cycle_row_id: cycle.id,
      cycle_name: cycle.name,
      enrolled: enrolled,
      skipped_ids: skipped.map(&:id),
      skipped_names: skipped.map(&:name)
    ).deliver(user)
  end

  # The assessed role/level snapshot for the enrollment event — same lookup
  # the single-enroll controller action performs.
  def assignment_role_level(cycle, person_id)
    assignment = PersonFrameworkAssignment.find_by(
      person_id: person_id, framework_id: cycle.framework_id
    )
    [ assignment&.role_id, assignment&.level_id ]
  end
end
