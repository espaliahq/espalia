# frozen_string_literal: true

# Resolves the framework context for evidence "cells" — the capability name,
# the assessee's role + that role's level title, the behavioural expectation
# ("what good looks like"), and the role illustrations ("examples") — plus the
# assessee's name and assignment id.
#
# This is the single source of cell context shared by the evidence hub (batch,
# over requests / authored items) and the unified evidence modal (single cell).
# Read-model joins only — no shared row, no extra denormalisation.
#
# A "cell" is any object responding to: `id`, `framework_id`, `person_id`,
# `capability_stable_id`, `level_ordinal`. EvidenceRequest and EvidenceItem both
# satisfy this; the modal builds a lightweight {Cell} from an assignment + coords.
class Evidence::CellContextResolver
  # Lightweight cell for callers that don't have a request/item record.
  Cell = Data.define(:id, :framework_id, :person_id, :capability_stable_id, :level_ordinal)

  # @param cells [Enumerable] objects with the cell duck type
  def initialize(cells)
    @cells = cells.to_a
  end

  # Resolve a single cell's context.
  #
  # @return [Hash] see {#by_id} value shape
  def self.context(framework_id:, person_id:, capability_stable_id:, level_ordinal:, id: :cell)
    cell = Cell.new(id:, framework_id:, person_id:, capability_stable_id:, level_ordinal:)
    new([ cell ]).by_id.fetch(id)
  end

  # @return [Hash{Object => Hash}] cell.id =>
  #   { capability_id:, name:, role:, role_id:, level_title:, expectation:,
  #     expectation_id:, illustrations: [String], assessee_name:, assignment_id: }
  def by_id
    return {} if @cells.empty?

    capability_ids = capability_id_lookup
    roles = role_lookup
    role_names = role_name_lookup(roles.values)
    assessee_names = Person.where(id: @cells.map(&:person_id).uniq).pluck(:id, :name).to_h
    assignment_ids = assignment_id_lookup

    @cells.each_with_object({}) do |cell, acc|
      capability_id = capability_ids[[ cell.framework_id, cell.capability_stable_id ]]
      role_id = roles[[ cell.framework_id, cell.person_id ]]
      expectation = capability_id &&
        FrameworkState::BehaviouralExpectation.find_by(capability_id: capability_id, level_ordinal: cell.level_ordinal)

      acc[cell.id] = {
        capability_id: capability_id,
        name: capability_id && FrameworkState::Capability.where(capability_id: capability_id).pick(:name),
        role: role_names[role_id],
        role_id: role_id,
        level_title: level_title_for(role_id, cell.level_ordinal),
        expectation: expectation&.description,
        expectation_id: expectation&.expectation_id,
        illustrations: illustrations_for(expectation, role_id),
        assessee_name: assessee_names[cell.person_id],
        assignment_id: assignment_ids[[ cell.framework_id, cell.person_id ]]
      }
    end
  end

  private

  # [framework_id, capability_stable_id] => capability_id
  def capability_id_lookup
    @cells.group_by(&:framework_id).each_with_object({}) do |(framework_id, cells), acc|
      FrameworkState::Capability
        .joins(:category)
        .where(stable_id: cells.map(&:capability_stable_id).uniq)
        .merge(FrameworkState::CapabilityCategory.where(framework_id: framework_id))
        .pluck(:stable_id, :capability_id)
        .each { |stable_id, capability_id| acc[[ framework_id, stable_id ]] = capability_id }
    end
  end

  # [framework_id, person_id] => role_id
  def role_lookup
    distinct_assignments.transform_values { |row| row&.first }
  end

  # [framework_id, person_id] => assignment_id
  def assignment_id_lookup
    distinct_assignments.transform_values { |row| row&.last }
  end

  # [framework_id, person_id] => [role_id, assignment_id], memoised (one query set)
  def distinct_assignments
    @distinct_assignments ||= @cells.map { |c| [ c.framework_id, c.person_id ] }.uniq.each_with_object({}) do |(fw, pid), acc|
      acc[[ fw, pid ]] = PersonFrameworkAssignment.where(framework_id: fw, person_id: pid).pick(:role_id, :id)
    end
  end

  def role_name_lookup(role_ids)
    ids = role_ids.map { |row| row.is_a?(Array) ? row.first : row }.compact.uniq
    return {} if ids.empty?

    FrameworkState::Role.where(role_id: ids).pluck(:role_id, :name).to_h
  end

  def level_title_for(role_id, level_ordinal)
    return nil if role_id.nil?

    FrameworkState::Level.where(role_id: role_id, ordinal: level_ordinal).pick(:title)
  end

  def illustrations_for(expectation, role_id)
    return [] if expectation.nil? || role_id.nil?

    FrameworkState::RoleIllustration
      .where(expectation_id: expectation.expectation_id, role_id: role_id)
      .order(:ordinal)
      .pluck(:description)
  end
end
