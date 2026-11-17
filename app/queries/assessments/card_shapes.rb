# frozen_string_literal: true

# The capability shape each assessment card shows: the hero's own, built by
# the same {Assessments::MatrixDataBuilder} through the home lens, in the
# context and from the ratings the viewer sees on opening the assessment. A
# listing loads every card's inputs together, so the page's query count
# doesn't grow with its cards; only a role it hasn't met yet costs more.
class Assessments::CardShapes
  # @param assignments [Array<PersonFrameworkAssignment>] cards the viewer can open
  # @param viewer_person_id [String]
  def initialize(assignments:, viewer_person_id:)
    @assignments = assignments
    @viewer_person_id = viewer_person_id
  end

  # @return [Hash{String => Assessments::CapabilityShape}] by assignment id;
  #   only the cards whose hero shows a score
  def call
    Assessments::RoleScope.reusing do
      role_ids_by_framework.each do |framework_id, role_ids|
        Assessments::RoleScope.for_roles(role_ids: role_ids, framework_id: framework_id)
      end
      @assignments.each_with_object({}) do |assignment, shapes|
        shape = shape_for(assignment)
        shapes[assignment.id] = shape if shape&.scored?
      end
    end
  end

  private

  def shape_for(assignment)
    lens = lenses[assignment]
    framework = frameworks[assignment.framework_id]
    return unless lens && framework

    context = Assessments::ViewerContext.for_listed(assignment: assignment, viewer_person_id: @viewer_person_id,
                                                    participation: lens.participation)
    data = Assessments::MatrixDataBuilder.new(
      framework: framework, lens: lens, person_id: assignment.person_id, cycle_id: lens.cycle.cycle_id,
      categories: trees.fetch(lens.framework_id), participant_status: lens.participant_status, context: context,
      disclosure: Assessments::Disclosure.for(lens: lens, participant_status: lens.participant_status,
                                              rows: alignments.fetch([ lens.cycle.cycle_id, assignment.person_id ], [])),
      ratings: ratings_for(lens)
    ).build
    Assessments::CapabilityShape.new(categories: data[:categories], scoring: hero_scoring(data, context),
                                     merged_levels: data[:merged_levels], person_level: data[:person_level],
                                     context: context)
  end

  # The perspective the hero renders for this context.
  def hero_scoring(data, context)
    key = { self: :self_scoring, manager: :manager_scoring, alignment: :aligned_scoring }[context]
    data[key] || data[:scoring]
  end

  # The open cycle's home lens, as {Assessments::Lens.home} resolves it. None
  # outside a cycle, which has no ratings to show.
  def lens_for(assignment)
    enrollment = enrollments[[ assignment.framework_id, assignment.person_id ]]
    return unless enrollment

    role_id, level_id = home_ids(assignment, enrollment)
    role = roles[role_id]
    level = role&.levels&.find { |lvl| lvl.level_id == level_id }
    return unless level

    Assessments::Lens.new(assignment: assignment, role: role, level: level, home_role: role, home_level: level,
                          cycle: enrollment.cycle, open_cycle_id: enrollment.cycle_id,
                          participation: participations[[ enrollment.cycle_id, enrollment.person_id ]])
  end

  # The enrollment snapshot's role and level, else the live assignment's.
  def home_ids(assignment, enrollment)
    return [ enrollment.role_id, enrollment.level_id ] if enrollment.role_id && enrollment.level_id

    [ assignment.role_id, assignment.level_id ]
  end

  # One tree per framework for every role its cards read.
  def trees
    @trees ||= lenses.values.compact.group_by(&:framework_id).to_h do |framework_id, framework_lenses|
      [ framework_id, Assessments::MatrixDataBuilder.lens_tree(framework_id: framework_id, lenses: framework_lenses) ]
    end
  end

  def lenses
    @lenses ||= @assignments.index_with { |assignment| lens_for(assignment) }
  end

  def ratings_for(lens)
    rows = ratings.fetch([ lens.assignment.person_id, lens.framework_id, lens.cycle.cycle_id ], [])
    rows.select { |r| lens.scope.include?(r.capability_stable_id, r.level_ordinal) }
  end

  # @return [Hash{Array(String, String) => AssessmentCycleEnrollment}] the open
  #   cycle's, by framework and person
  def enrollments
    @enrollments ||= AssessmentCycleEnrollment
      .where(person_id: @assignments.map(&:person_id).uniq)
      .where.not(status: "withdrawn")
      .eager_load(:cycle)
      .where(assessment_cycles: { framework_id: @assignments.map(&:framework_id).uniq, status: "open" })
      .index_by { |enrollment| [ enrollment.cycle.framework_id, enrollment.person_id ] }
  end

  def participations
    @participations ||= AssessmentCycleParticipation.for_enrollments(enrollments.values)
      .index_by { |participation| [ participation.enrollment.cycle_id, participation.enrollment.person_id ] }
  end

  def alignments
    @alignments ||= AssessmentCycleRoleAlignment
      .where(cycle_id: enrollments.values.map(&:cycle_id).uniq, person_id: enrollments.values.map(&:person_id).uniq)
      .group_by { |row| [ row.cycle_id, row.person_id ] }
  end

  # Every card's people at once, each read through its own lens's role in
  # {#ratings_for}: a person can hold assignments on more than one framework.
  def ratings
    @ratings ||= AssessmentLevelRating.across_all_roles
      .where(cycle_id: enrollments.values.map(&:cycle_id).uniq, person_id: enrollments.values.map(&:person_id).uniq)
      .group_by { |r| [ r.person_id, r.framework_id, r.cycle_id ] }
  end

  def role_ids_by_framework
    @assignments.group_by(&:framework_id).transform_values do |list|
      list.flat_map { |a| [ a.role_id, enrollments[[ a.framework_id, a.person_id ]]&.role_id ] }.compact.uniq
    end
  end

  def roles
    @roles ||= FrameworkState::Role.includes(:levels)
      .where(role_id: role_ids_by_framework.values.flatten.uniq).index_by(&:role_id)
  end

  def frameworks
    @frameworks ||= FrameworkState::Framework.where(framework_id: @assignments.map(&:framework_id).uniq)
      .index_by(&:framework_id)
  end
end
