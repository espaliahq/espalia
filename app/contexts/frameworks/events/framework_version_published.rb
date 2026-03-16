# frozen_string_literal: true

# Event emitted when a draft version is published.
#
# Closes the draft phase. The published projection advances to include
# all structural events that accumulated during the draft.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [Integer] :version the published version number
#   @option data [String] :published_by UUID of the user who published
#
class Frameworks::Events::FrameworkVersionPublished < RubyEventStore::Event
end
