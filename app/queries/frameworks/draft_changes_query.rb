# frozen_string_literal: true

# What publishing the open draft changes in the rating grid, so the person
# confirming it can see what they are about to make live.
#
# A diff of the edit-mode graph against the published read model, not a walk
# of the events: a binding removed and then re-added in the same draft changes
# nothing, and must not be listed.
#
# Lists only shape-changing changes — the ones held back until publish.
# Renames, rewordings and examples apply live, so they are already published.
class Frameworks::DraftChangesQuery
  # The order the review page lists the kinds in.
  KINDS = %i[
    capabilities_added capabilities_archived categories_archived
    roles_removed roles_added levels_added levels_moved expectations_added
  ].freeze

  # @param framework [FrameworkState::Framework]
  def initialize(framework)
    @framework = framework
  end

  # @return [Hash{Symbol => Array<Hash>}] each of {KINDS}, possibly empty
  def call
    @call ||= KINDS.index_with { |kind| send(kind) }
  end

  # @return [Boolean]
  def empty? = call.values.all?(&:empty?)

  private

  # A capability added and archived in the same draft never goes live.
  def capabilities_added
    capabilities.select { |c| c.added_in_draft && !leaving?(c) }.map do |c|
      { capability: c.name, category: category_names[c.category_id],
        roles: c.bindings.filter_map { |b| role_name(b.role_id) }.sort }
    end
  end

  # The same list the mapping form below it shows, so the two can't disagree.
  # Counted over the roles it is published with: a role removed earlier in the
  # draft still holds people the archive reaches.
  def capabilities_archived
    Frameworks::RetiringCapabilitiesQuery.new(@framework).call.map do |entry|
      capability = entry[:capability]
      role_ids = capability.bindings.map(&:role_id) +
                 published_bindings.select { |b| b.capability_id == capability.capability_id }.map(&:role_id)
      { capability: capability.name, open_cycle_people: open_cycle_people(role_ids) }
    end
  end

  def categories_archived
    published_active = FrameworkState::CapabilityCategory
      .where(framework_id: @framework.framework_id, status: "active").pluck(:category_id).to_set
    graph.capability_categories
      .select { |cat| cat.status == "archived" && published_active.include?(cat.category_id) }
      .map { |cat| { category: cat.name } }
  end

  # Compared by (capability, role), not binding id: removing a binding and
  # adding it back mints a new id for what is, to an assessment, no change.
  # An archived capability loses every role with it, and is listed once, as
  # the archive.
  def roles_removed
    leaving = capabilities.select { |c| leaving?(c) }.map(&:capability_id).to_set

    published_bindings
      .reject { |b| draft_pairs.include?([ b.capability_id, b.role_id ]) || leaving.include?(b.capability_id) }
      .map do |b|
        { capability: capability_name(b.capability_id), role: role_name(b.role_id),
          open_cycle_people: open_cycle_people([ b.role_id ]) }
      end
  end

  # A new capability's roles are part of adding it.
  def roles_added
    staying_capabilities.reject(&:added_in_draft).flat_map do |c|
      c.bindings
        .reject { |b| published_pairs.include?([ c.capability_id, b.role_id ]) }
        .map { |b| { capability: c.name, role: role_name(b.role_id) } }
    end
  end

  def levels_added
    roles.flat_map do |role|
      role.levels.select(&:added_in_draft).map do |level|
        { role: role_label(role), level: level_label(level), title: level.title }
      end
    end
  end

  # A level moved to another ordinal re-keys that role's rating grid.
  def levels_moved
    published = FrameworkState::Level.where(level_id: roles.flat_map(&:levels).map(&:level_id))
      .pluck(:level_id, :ordinal).to_h
    roles.flat_map do |role|
      role.levels.reject(&:added_in_draft).filter_map do |level|
        from = published[level.level_id]
        next if from.nil? || from == level.ordinal

        { role: role_label(role), level: level_label(level), title: level.title, from: from, to: level.ordinal }
      end
    end
  end

  def expectations_added
    staying_capabilities.reject(&:added_in_draft).flat_map do |c|
      c.expectations.select(&:added_in_draft).map { |e| { capability: c.name, level_ordinal: e.level_ordinal } }
    end
  end

  def leaving?(capability) = capability.pending_archive || capability.status == "archived"

  def staying_capabilities = capabilities.reject { |c| leaving?(c) }

  # People in an open cycle of this framework assessed in one of `role_ids` —
  # by their enrollment snapshot's role, else their assignment's, the same
  # rule every assessment reader uses.
  def open_cycle_people(role_ids)
    role_ids.uniq.flat_map { |role_id| people_by_role.fetch(role_id, []) }.uniq.size
  end

  def people_by_role
    @people_by_role ||= begin
      by_role = Hash.new { |h, k| h[k] = [] }
      AssessmentCycle.open_cycles.for_framework(@framework.framework_id).pluck(:cycle_id).each do |cycle_id|
        person_ids = AssessmentCycleEnrollment.active.where(cycle_id: cycle_id).pluck(:person_id)
        Assessments::RoleScope
          .home_role_ids(cycle_id: cycle_id, framework_id: @framework.framework_id, person_ids: person_ids)
          .each { |person_id, role_id| by_role[role_id] << person_id }
      end
      by_role
    end
  end

  def published_bindings
    @published_bindings ||= FrameworkState::CapabilityRoleBinding
      .where(capability_id: published_capability_ids)
      .to_a
  end

  def published_capability_ids
    FrameworkState::Capability
      .joins(:category).where(framework_capability_categories: { framework_id: @framework.framework_id })
      .where(status: "active")
      .pluck(:capability_id)
  end

  def published_pairs
    @published_pairs ||= published_bindings.to_set { |b| [ b.capability_id, b.role_id ] }
  end

  def draft_pairs
    @draft_pairs ||= capabilities.flat_map { |c| c.bindings.map { |b| [ c.capability_id, b.role_id ] } }.to_set
  end

  def role_label(role) = "#{role.code} · #{role.name}"

  def level_label(level) = level.code.presence || "L#{level.ordinal}"

  def capability_name(capability_id)
    @capability_names ||= capabilities.to_h { |c| [ c.capability_id, c.name ] }
    @capability_names[capability_id]
  end

  def role_name(role_id)
    @role_names ||= roles.to_h { |r| [ r.role_id, r.name ] }
    @role_names[role_id]
  end

  def category_names
    @category_names ||= graph.capability_categories.to_h { |cat| [ cat.category_id, cat.name ] }
  end

  def capabilities
    @capabilities ||= graph.capability_categories.flat_map(&:capabilities)
  end

  def roles
    @roles ||= graph.role_families.flat_map(&:roles)
  end

  def graph
    @graph ||= Frameworks::ExplorerGraph.load(@framework.framework_id) ||
               Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end
end
