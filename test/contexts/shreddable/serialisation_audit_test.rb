# frozen_string_literal: true

require "test_helper"

# The assessment and framework activity feeds copy each event's whole data
# into a payload, and the MCP recent_activity tools serialise it as JSON. A
# shreddable value there would raise, so those contexts must declare none
# until their feeds reveal or drop declared fields first.
class Shreddable::SerialisationAuditTest < ActiveSupport::TestCase
  FEED_CONTEXTS = %w[PersonDevelopment Frameworks].freeze

  should "keep shreddable fields out of the contexts whose feeds serialise whole events" do
    Rails.application.eager_load!
    declaring = ObjectSpace.each_object(Class).select do |klass|
      klass < RubyEventStore::Event && FEED_CONTEXTS.include?(klass.name.to_s.split("::").first) &&
        klass.respond_to?(:shreddable_fields) && klass.shreddable_fields.any?
    end

    assert_empty declaring.map(&:name)
  end
end
