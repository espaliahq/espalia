# frozen_string_literal: true

# "Awaiting you" — direct reports who still need this manager's rating or the
# alignment conversation in an open cycle. A single instance summarising across
# reports. This is the manager's *own keyboard* (act now), as opposed to the
# cohort card's oversight framing (track + chase).
#
# Scope is deliberately the manager's *direct* reports — a manager only
# personally rates and aligns their direct reports. Org-wide oversight across
# the whole subtree is the cohort card's job.
class Home::AwaitingYouCard < Home::Card
  PRIORITY = 60
  PREVIEW_LIMIT = 5

  def self.key = "awaiting_you"

  def self.audience?(context)
    person = context.person
    return false unless person

    pending_reports(person).exists?
  end

  def self.instances(context)
    person = context.person
    return [] unless person
    return [] unless pending_reports(person).exists?

    [ build_instance(priority: PRIORITY, title: "Awaiting you") ]
  end

  # Progress rows for direct reports who are actively enrolled in an open cycle
  # and not yet `aligned` — i.e. the manager still owes them a rating or the
  # alignment conversation. Correlated to an active enrollment so withdrawn
  # reports (whose progress row is retained) don't show up.
  # @return [ActiveRecord::Relation<AssessmentCycleProgress>]
  def self.pending_reports(person)
    report_ids = person.direct_reports.select(:id)
    active_enrollment = AssessmentCycleEnrollment
      .active
      .where("assessment_cycle_enrollments.cycle_id = assessment_cycle_progress.cycle_id")
      .where("assessment_cycle_enrollments.person_id = assessment_cycle_progress.person_id")

    AssessmentCycleProgress
      .where(person_id: report_ids)
      .where.not(status: "aligned")
      .joins(:cycle)
      .where(assessment_cycles: { status: "open" })
      .where(active_enrollment.arel.exists)
  end
  private_class_method :pending_reports

  def render_content(_instance_key)
    rows = self.class.send(:pending_reports, person).includes(:person, :cycle).to_a

    Views::Home::Cards::AwaitingYou.new(
      reports: rows.map { |row| { person: row.person, cycle: row.cycle, status: row.status } }
    )
  end
end
