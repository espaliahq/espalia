# frozen_string_literal: true

# Event emitted when a draft phase begins for a new framework version.
#
# Structural events between this and FrameworkVersionPublished are
# invisible to the published projection — only the draft/editor view
# includes them.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [Integer] :target_version the version number being drafted
#   @option data [String] :started_by UUID of the user who started the draft
#
class Frameworks::Events::DraftVersionStarted < RubyEventStore::Event
end
