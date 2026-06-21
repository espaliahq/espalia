# frozen_string_literal: true

# Builds the option data the evidence modal's "also applies to" picker needs
# for one framework + assignee role: the selectable capabilities (grouped by
# category), the role's levels, and the behavioural expectation for every valid
# (capability × level) cell.
#
# A cell is valid — and therefore linkable — exactly when the matrix would show
# it: the capability is active and bound to the role, and a BehaviouralExpectation
# exists at that level. The expectation_map carries that text so the picker can
# show, for each linked cell, which behaviour the evidence must satisfy.
class Evidence::FrameworkCellOptions
  # @param framework_id [String]
  # @param role_id [String] the assignee's role
  def initialize(framework_id:, role_id:)
    @framework_id = framework_id
    @role_id = role_id
  end

  # @return [Array<Hash>] [{ category_name:, capabilities: [{ stable_id:, name: }] }]
  def link_options
    capabilities_by_category.map do |category, caps|
      { category_name: category.name, capabilities: caps.map { |c| { stable_id: c.stable_id, name: c.name } } }
    end
  end

  # @return [Array<Hash>] [{ ordinal:, label: }] in level order
  def level_options
    levels.map { |level| { ordinal: level.ordinal, label: level_label(level) } }
  end

  # @return [Hash{String => Hash}] "stableId|ordinal" => { capability_name:, expectation: }
  #   for every valid cell — the source of truth for both validity and the
  #   linked-cell expectation text shown in the picker.
  def expectation_map
    cap_by_id = capabilities.index_by(&:capability_id)
    expectations.each_with_object({}) do |expectation, map|
      cap = cap_by_id[expectation.capability_id]
      next unless cap

      map["#{cap.stable_id}|#{expectation.level_ordinal}"] =
        { capability_name: cap.name, expectation: expectation.description }
    end
  end

  private

  def levels
    @levels ||= FrameworkState::Level.where(role_id: @role_id).order(:ordinal).to_a
  end

  def level_label(level)
    level.title.present? ? "L#{level.ordinal} — #{level.title}" : "L#{level.ordinal}"
  end

  def bound_capability_ids
    @bound_capability_ids ||= FrameworkState::CapabilityRoleBinding.where(role_id: @role_id).pluck(:capability_id)
  end

  def capabilities
    @capabilities ||= FrameworkState::Capability
      .where(capability_id: bound_capability_ids, status: "active")
      .includes(:category)
      .to_a
  end

  def capabilities_by_category
    capabilities
      .group_by(&:category)
      .sort_by { |category, _| [ category&.ordinal || Float::INFINITY, category&.name.to_s ] }
      .map { |category, caps| [ category, caps.sort_by { |c| c.name.to_s } ] }
  end

  def expectations
    @expectations ||= FrameworkState::BehaviouralExpectation.where(capability_id: bound_capability_ids).to_a
  end
end
