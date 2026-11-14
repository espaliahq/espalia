# frozen_string_literal: true

require "test_helper"

class Shreddable::MapperTest < ActiveSupport::TestCase
  class NoteWritten < RubyEventStore::Event
    extend Shreddable
    shreddable :note, by: :plan
    shreddable :pay, by: :person
  end

  class Copied < RubyEventStore::Event; end

  setup do
    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
    @plan_id = SecureRandom.uuid_v7
    @event_store = Rails.configuration.event_store
    @stream = "tenant-#{@tenant.id}/ShreddableTest-#{@plan_id}"
  end

  def in_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def note_written(note: "Moving to the platform team", pay: { "amount" => 182_000 })
    NoteWritten.new(data: { plan_id: @plan_id, person_id: @person.id, note: note, pay: pay })
  end

  def publish(event)
    in_tenant { @event_store.with_metadata(tenant_id: @tenant.id) { @event_store.publish(event, stream_name: @stream) } }
    event
  end

  def read_back = in_tenant { @event_store.read.stream(@stream).to_a.sole }

  def stored_row
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT convert_from(data, 'UTF8') AS data, convert_from(metadata, 'UTF8') AS metadata FROM event_store_events WHERE event_id = ?", read_back.event_id ])
    ActiveRecord::Base.connection.select_one(sql).transform_values { JSON.parse(it) }
  end

  should "read a shreddable field back as the value written" do
    publish(note_written)
    event = read_back

    assert_equal "Moving to the platform team", event.data[:note].reveal
    assert_equal({ "amount" => 182_000 }, event.data[:pay].reveal)
    assert_equal @person.id, event.data[:person_id]
    assert_nil event.metadata[:shreddable]
  end

  should "store the field as ciphertext, under the plan key and the person's key" do
    publish(note_written)
    row = stored_row

    assert_not_includes row["data"].to_s, "platform team"
    assert_not_includes row["data"].to_s, "182000"
    description = row["metadata"].fetch("shreddable")
    assert_equal PlanKeyStore.plan_identifier(@tenant.id, @plan_id), description.dig("note", "identifier")
    assert_equal PlanKeyStore.person_identifier(@tenant.id, @plan_id, @person.id), description.dig("pay", "identifier")
  end

  should "read a field as removed once its key is destroyed, leaving the others" do
    publish(note_written)
    in_tenant { PlanKeyStore.new.destroy_person(@person.id) }
    event = read_back

    assert_predicate event.data[:pay], :removed?
    assert_nil event.data[:pay].reveal
    assert_equal "Moving to the platform team", event.data[:note].reveal
  end

  should "read every field as removed once the plan is deleted" do
    publish(note_written)
    in_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }

    assert read_back.data.values_at(:note, :pay).all?(&:removed?)
  end

  should "refuse to write for a plan already deleted" do
    in_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }

    assert_raises(PlanKeyStore::Destroyed) { publish(note_written) }
  end

  should "write a nil field as nil, with no key" do
    publish(note_written(note: nil, pay: nil))

    assert_nil read_back.data[:note]
    assert_empty PlanEncryptionKey.unscoped.where(plan_id: @plan_id)
  end

  should "hand subscribers the real value, not a removed one" do
    seen = []
    @event_store.within { publish(note_written) }.subscribe(->(event) { seen << event.data[:note] }, to: [ NoteWritten ]).call

    assert_equal "Moving to the platform team", seen.sole.reveal
  end

  should "refuse to copy a value into a field not declared shreddable" do
    value = note_written.data[:note]

    assert_raises(Shreddable::Value::Unserialisable) { publish(Copied.new(data: { plan_id: @plan_id, note: value })) }
  end

  should "refuse to write a removed value again" do
    assert_raises(ArgumentError) { publish(note_written(note: Shreddable::Value.removed)) }
  end
end
