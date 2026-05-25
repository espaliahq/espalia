# frozen_string_literal: true

# Event emitted when a capability category is archived.
#
# Archiving requires the category to hold no active capabilities — the
# aggregate enforces that precondition before applying the event. Unlike
# capability archival there is no migration mapping requirement, because
# categories do not carry ratings; capabilities do.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :category_id UUID of the category
#   @option data [String] :reason reason for archiving
#
class Frameworks::Events::CapabilityCategoryArchived < RubyEventStore::Event
end
