# frozen_string_literal: true

require "test_helper"

class Shreddable::ValueTest < ActiveSupport::TestCase
  setup { @value = Shreddable::Value.new("Moving to the platform team") }

  should "be read only through reveal" do
    assert_equal "Moving to the platform team", @value.reveal
    assert_equal "[shreddable]", @value.to_s
    assert_equal "[shreddable]", "#{@value}"
    assert_not_includes @value.inspect, "platform"
    assert_not_includes [ @value ].pretty_inspect, "platform"
    assert_not_includes({ note: @value }.inspect, "platform")
  end

  should "refuse to serialise in clear" do
    assert_raises(Shreddable::Value::Unserialisable) { @value.to_json }
    assert_raises(Shreddable::Value::Unserialisable) { JSON.generate(note: @value) }
    assert_raises(Shreddable::Value::Unserialisable) { { note: @value }.as_json }
    assert_raises(Shreddable::Value::Unserialisable) { YAML.dump(@value) }
    assert_raises(Shreddable::Value::Unserialisable) { Marshal.dump(@value) }
  end

  should "let a removed value round-trip through Marshal, holding nothing" do
    assert_equal Shreddable::Value.removed, Marshal.load(Marshal.dump(Shreddable::Value.removed))
    assert_equal "[removed]", Shreddable::Value.removed.to_s
  end

  should "wrap once, and leave nil alone" do
    assert_same @value, Shreddable::Value.wrap(@value)
    assert_nil Shreddable::Value.wrap(nil)
    assert_equal @value, Shreddable::Value.wrap("Moving to the platform team")
  end
end
