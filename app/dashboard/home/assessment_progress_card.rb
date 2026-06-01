# frozen_string_literal: true

# "Your assessment progress" — one instance per open cycle the viewer is
# enrolled in as the assessee. This is the viewer's *own keyboard*: a nudge to
# continue their self-assessment (distinct from the manager-facing
# {Home::AwaitingYouCard}, which is about acting on reports).
class Home::AssessmentProgressCard < Home::Card
  PRIORITY = 50

  def self.key = "assessment_progress"

  def self.audience?(context)
    person = context.person
    return false unless person

    open_enrollments(person).exists?
  end

  def self.instances(context)
    person = context.person
    return [] unless person

    open_enrollments(person).includes(:cycle).map do |enrollment|
      build_instance(
        instance_key: enrollment.cycle_id,
        priority: PRIORITY,
        title: enrollment.cycle.name
      )
    end
  end

  # Active enrollments of this person in currently-open cycles.
  # @return [ActiveRecord::Relation<AssessmentCycleEnrollment>]
  def self.open_enrollments(person)
    AssessmentCycleEnrollment
      .active
      .for_person(person.id)
      .joins(:cycle)
      .where(assessment_cycles: { status: "open" })
  end
  private_class_method :open_enrollments

  def render_content(instance_key)
    enrollment = self.class.send(:open_enrollments, person)
      .includes(:cycle)
      .find_by(cycle_id: instance_key)
    return Views::Home::Cards::AssessmentProgress.new(state: nil) unless enrollment

    cycle = enrollment.cycle
    assignment = PersonFrameworkAssignment
      .for_person(person.id)
      .find_by(framework_id: cycle.framework_id)
    progress = AssessmentCycleProgress.find_by(cycle_id: cycle.cycle_id, person_id: person.id)
    rated = AssessmentLevelRating
      .for_cycle(cycle.cycle_id)
      .for_person(person.id)
      .self_rated
      .count

    Views::Home::Cards::AssessmentProgress.new(
      state: {
        cycle: cycle,
        assignment: assignment,
        status: progress&.status || "in_progress",
        self_rated_count: rated
      }
    )
  end
end
