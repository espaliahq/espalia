# frozen_string_literal: true

# Removing a unit type waits only for live plans' current changes, so undo and
# redo can bring back a unit of a type that has gone since.
module Operations::TeamPlanning::UnitTypeRemains
  private

  # Call it under the plan's lock: it takes the structure's next, the same order as every other path.
  #
  # @param change [RubyEventStore::Event, nil] the change brought back
  # @raise [Operations::Base::ParameterError] when it places a unit of a removed type
  def unit_type_remains!(change)
    return unless change.is_a?(::TeamPlanning::Events::UnitSet)

    ::OrgGraph::Repository.new.lock_structure # so a type can't be removed between this check and the write
    return unless unit_type_removed?(change)

    raise Operations::Base::ParameterError,
          "This change places a unit of a type that has been removed, so it can't be brought back"
  end

  # @param change [RubyEventStore::Event, nil] the change brought back
  # @return [Boolean] whether it places a unit of a type that has gone
  def unit_type_removed?(change)
    change.is_a?(::TeamPlanning::Events::UnitSet) && !OrgTaxonomyLevel.exists?(id: change.data[:level_id])
  end
end
