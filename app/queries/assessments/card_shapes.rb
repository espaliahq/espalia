# frozen_string_literal: true

# Each assessment card's capability shape, built as its hero builds it and
# loaded for every card at once, so the list's query count doesn't grow with
# its cards.
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
      preload_role_scopes
      @assignments.each_with_object({}) do |assignment, shapes|
        shape = shape_for(assignment)
        shapes[assignment.id] = shape if shape&.scored?
      end
    end
  end

  private

  def shape_for(assignment)
    lens = lenses[assignment]
    return unless lens

    context = Assessments::ViewerContext.for_listed(assignment: assignment, viewer_person_id: @viewer_person_id,
                                                    participation: lens.participation)
    key = [ lens.cycle.cycle_id, assignment.person_id ]
    data = Assessments::MatrixDataBuilder.for_lens(
      lens: lens, context: context, framework: frameworks[lens.framework_id],
      categories: trees.fetch(lens.framework_id), alignments: alignments.fetch(key, []), roles: roles,
      ratings: ratings.fetch(key, [])
    )
    Assessments::CapabilityShape.new(categories: data[:categories], scoring: hero_scoring(data, context),
                                     merged_levels: data[:merged_levels], person_level: data[:person_level],
                                     context: context)
  end

  # The perspective the hero renders for this context.
  def hero_scoring(data, context)
    key = { self: :self_scoring, manager: :manager_scoring, alignment: :aligned_scoring }[context]
    data[key] || data[:scoring]
  end

  # The open cycle's home lens per card; none outside a cycle, which has no
  # ratings to show.
  def lenses
    @lenses ||= @assignments.index_with do |assignment|
      enrollment = enrollment_for(assignment)
      next unless enrollment && frameworks[assignment.framework_id]

      Assessments::Lens.preloaded_home(assignment: assignment, enrollment: enrollment, roles: roles,
                                       participation: participations[[ enrollment.cycle_id, enrollment.person_id ]])
    end
  end

  # One tree per framework for every role its cards read.
  def trees
    @trees ||= lenses.values.compact.group_by(&:framework_id).to_h do |framework_id, framework_lenses|
      [ framework_id, Assessments::MatrixDataBuilder.lens_tree(framework_id: framework_id, lenses: framework_lenses) ]
    end
  end

  # Fills {Assessments::RoleScope.reusing}'s memo, one load per framework, so
  # each lens's and alignment's scope reads from it.
  def preload_role_scopes
    role_ids_by_framework.each do |framework_id, role_ids|
      Assessments::RoleScope.for_roles(role_ids: role_ids, framework_id: framework_id)
    end
  end

  # The home roles of the cards in a cycle, and the roles of their alignments.
  def role_ids_by_framework
    @role_ids_by_framework ||= enrolled.group_by(&:framework_id).transform_values do |list|
      homes = list.map { |a| Assessments::Lens.home_ids(a, enrollment_for(a)).first }
      aligned = list.flat_map { |a| alignments.fetch([ enrollment_for(a).cycle_id, a.person_id ], []).map(&:role_id) }
      (homes + aligned).uniq
    end
  end

  def enrolled = @assignments.select { |assignment| enrollment_for(assignment) }

  def enrollment_for(assignment) = enrollments[[ assignment.framework_id, assignment.person_id ]]

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

  # The rest key by cycle and person.
  def participations
    @participations ||= AssessmentCycleParticipation.for_enrollments(enrollments.values)
      .index_by { |participation| [ participation.enrollment.cycle_id, participation.enrollment.person_id ] }
  end

  def alignments
    @alignments ||= AssessmentCycleRoleAlignment.where(cycle_id: cycle_ids, person_id: person_ids)
      .group_by { |row| [ row.cycle_id, row.person_id ] }
  end

  # Every card's ratings within its own role, one framework's people at a
  # time since a person's role differs between frameworks, in one query.
  def ratings
    @ratings ||= begin
      reads = lenses.values.compact.group_by(&:framework_id).filter_map do |framework_id, framework_lenses|
        scopes = framework_lenses.to_h { |lens| [ lens.assignment.person_id, lens.scope ] }
        next if scopes.values.all?(&:empty?)

        AssessmentLevelRating.for_framework(framework_id)
          .for_cycle(framework_lenses.map { |lens| lens.cycle.cycle_id }.uniq).within(scopes)
      end
      reads.empty? ? {} : reads.reduce(:or).group_by { |r| [ r.cycle_id, r.person_id ] }
    end
  end

  def cycle_ids = enrollments.values.map(&:cycle_id).uniq

  def person_ids = enrollments.values.map(&:person_id).uniq

  def roles
    @roles ||= FrameworkState::Role.includes(:levels).where(role_id: role_ids_by_framework.values.flatten.uniq)
      .index_by(&:role_id)
  end

  def frameworks
    @frameworks ||= FrameworkState::Framework.where(framework_id: @assignments.map(&:framework_id).uniq)
      .index_by(&:framework_id)
  end
end
