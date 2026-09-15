# frozen_string_literal: true

# Event emitted when a framework's display name is changed.
#
# Shape-preserving — the name does not touch the rating grid, so it applies
# live regardless of draft state (no draft opened, no migration mapping).
# Carries the full new name (not a diff); the aggregate no-ops on an unchanged
# name so a stream never holds a rename to the same value.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :name the new display name
#
class Frameworks::Events::FrameworkRenamed < RubyEventStore::Event
end
