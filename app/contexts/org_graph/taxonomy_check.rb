# frozen_string_literal: true

# What a tenant's structure stream holds that the rules for kinds of unit
# would not accept, each unit judged by the structure in force where it sits:
# a live unit beneath a parent its kind may not sit under, or at the top when
# its kind may not sit there, and a change to the kinds
# dated before an earlier one. A misplaced unit must be moved before kinds
# can state their rules; out-of-order dates only need knowing about, as the
# history lets event order decide.
#
# @example
#   ActsAsTenant.with_tenant(tenant) { OrgGraph::TaxonomyCheck.new.misplaced }
class OrgGraph::TaxonomyCheck
  DATED_CHANGES = [ OrgGraph::Events::TaxonomyDefined, OrgGraph::Events::LevelProviderSet ].freeze

  # @return [Integer] the structures the tenant holds: the top one and each a unit declared
  def structures = structure.declared_structures.size + 1

  # @return [Array<String>] one line per live unit its kind may not sit where it is
  def misplaced
    structure.misplaced_units.map do |unit|
      parent = unit.parent_id && structure.unit(unit.parent_id)
      declaring = structure.structure_in_force(unit.unit_id)
      place = if parent.nil? then "at the top"
      elsif parent.unit_id == declaring then "at the top of #{parent.name}'s structure"
      else "beneath #{parent.name} (#{kind_name(parent)})"
      end
      "#{unit.name} (#{kind_name(unit)}) sits #{place}, where its kind may not"
    end
  end

  # Each structure's changes are dated apart from the others'.
  #
  # @return [Array<String>] one line per change to a structure's kinds dated before an earlier one
  def out_of_order
    latest = {}
    events.filter_map do |event|
      on = Date.iso8601(event.data[:effective_on].to_s)
      key = event.data[:structure_unit_id]
      earlier = latest[key] && on < latest[key]
      latest[key] = [ latest[key], on ].compact.max
      "#{event.class.name.demodulize} #{event.event_id} is dated #{on}, before #{latest[key]}" if earlier
    end
  end

  private

  def structure = @structure ||= OrgGraph::Repository.new.load_structure

  # A misplaced unit's kind may come from another structure than the one in force.
  def kind_name(unit)
    [ structure.taxonomy, *structure.declared_structures.values ].filter_map { it.kind(unit.level_id) }.first&.name || unit.level_id
  end

  def events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream).of_type(DATED_CHANGES).to_a
  end
end
