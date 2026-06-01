# frozen_string_literal: true

# "Cycle progress (your org)" — oversight for managers and admins. One instance
# per open cycle the viewer's org participates in. The teaser shows the funnel,
# the at-risk count, and the most-lagging subtree; the CTA opens the full
# drill-down. Distinct from {Home::AwaitingYouCard} (act now) — this is track +
# chase.
#
# Audience is any relevant manager, not only managers-of-managers: a front-line
# manager sees their own slice; a skip-level manager sees their whole subtree;
# admins/HR see the whole cycle.
class Home::CycleProgressCard < Home::Card
  PRIORITY = 55

  def self.key = "cycle_progress"

  def self.audience?(context)
    visible_open_cycles(context).exists?
  end

  def self.instances(context)
    visible_open_cycles(context).order(:planned_end_at, :opened_at).map do |cycle|
      build_instance(instance_key: cycle.cycle_id, priority: PRIORITY, title: cycle.name)
    end
  end

  # Open cycles whose cohort this viewer may see: all open cycles for admins/HR;
  # otherwise cycles with an active participant somewhere in the viewer's subtree.
  # @return [ActiveRecord::Relation<AssessmentCycle>]
  def self.visible_open_cycles(context)
    return AssessmentCycle.open_cycles if full_access?(context)
    return AssessmentCycle.none unless context.person

    report_ids = context.person.all_reports.select(:id)
    cycle_ids = AssessmentCycleEnrollment.active.where(person_id: report_ids).select(:cycle_id)
    AssessmentCycle.open_cycles.where(cycle_id: cycle_ids)
  end

  # Admins / global admins act as HR (whole-cycle visibility) for v1.
  def self.full_access?(context)
    context.tenant_user&.admin? || context.user&.global_admin? || false
  end
  private_class_method :full_access?

  def render_content(instance_key)
    cycle = self.class.visible_open_cycles(context).find_by(cycle_id: instance_key)
    # The content endpoint is reachable by arbitrary instance key — enforce
    # per-cycle authorization here, not just the card-type audience check.
    raise Pundit::NotAuthorizedError unless cycle

    scope_ids = self.class.send(:full_access?, context) ? nil : person.all_reports.pluck(:id)
    result = Reporting::CycleCohort.new(cycle: cycle, scope_person_ids: scope_ids, mode: :summary).call

    Views::Home::Cards::CycleProgress.new(cycle: cycle, result: result)
  end
end
