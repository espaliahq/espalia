# frozen_string_literal: true

# What a tenant's structure stream holds that the rules for kinds of unit
# would not accept: a live unit beneath a parent its kind may not sit under,
# or at the top when its kind may not sit there, and a change to the kinds
# dated before an earlier one. A misplaced unit must be moved before kinds
# can state their rules; out-of-order dates only need knowing about, as the
# history lets event order decide.
#
# @example
#   ActsAsTenant.with_tenant(tenant) { OrgGraph::TaxonomyCheck.new.misplaced }
class OrgGraph::TaxonomyCheck
  DATED_CHANGES = [ OrgGraph::Events::TaxonomyDefined, OrgGraph::Events::LevelProviderSet ].freeze

  # @return [Array<String>] one line per live unit its kind may not sit where it is
  def misplaced
    structure = OrgGraph::Repository.new.load_structure
    taxonomy = structure.taxonomy
    structure.misplaced_units.map do |unit|
      parent = unit.parent_id && structure.unit(unit.parent_id)
      kind = taxonomy.kind(unit.level_id)&.name || unit.level_id
      place = parent ? "beneath #{parent.name} (#{taxonomy.kind(parent.level_id)&.name || parent.level_id})" : "at the top"
      "#{unit.name} (#{kind}) sits #{place}, where its kind may not"
    end
  end

  # @return [Array<String>] one line per change to the kinds dated before an earlier one
  def out_of_order
    latest = nil
    events.filter_map do |event|
      on = Date.iso8601(event.data[:effective_on].to_s)
      earlier = latest && on < latest
      latest = [ latest, on ].compact.max
      "#{event.class.name.demodulize} #{event.event_id} is dated #{on}, before #{latest}" if earlier
    end
  end

  private

  def events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream).of_type(DATED_CHANGES).to_a
  end
end
