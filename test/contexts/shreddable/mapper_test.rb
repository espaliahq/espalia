# frozen_string_literal: true

require "test_helper"

class Shreddable::MapperTest < ActiveSupport::TestCase
  class NoteWritten < RubyEventStore::Event
    extend Shreddable
    shreddable :note, by: :plan
    shreddable :pay, by: :person
  end

  class Copied < RubyEventStore::Event; end

  class SalaryNoteWritten < NoteWritten; end

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

  should "read without raising in a release that predates shreddable fields" do
    publish(note_written)
    record = in_tenant { @event_store.read.stream(@stream).to_a.sole }
    stored = Shreddable::Mapper.json_client_default.records_to_events([ RubyEventStore::SerializedRecord.new(
      event_id: record.event_id, event_type: "TeamPlanning::Events::NotYetKnown",
      data: stored_row["data"].to_json, metadata: stored_row["metadata"].to_json,
      timestamp: record.timestamp.iso8601(6), valid_at: record.valid_at.iso8601(6)
    ).deserialize(JSON) ]).sole

    assert_instance_of RubyEventStore::Event, stored
    assert_match(/\A[A-Za-z0-9+\/]+=*\z/, stored.data["note"] || stored.data[:note])
  end

  should "refuse to write a removed value again" do
    assert_raises(ArgumentError) { publish(note_written(note: Shreddable::Value.removed)) }
  end

  should "look up no key until a value is revealed" do
    publish(note_written)
    event = read_back

    assert_no_queries(include_schema: false) { assert_equal "[shreddable]", event.data[:note].to_s }
    assert_equal "Moving to the platform team", event.data[:note].reveal
  end

  should "read another tenant's records without touching their keys, and refuse to reveal them" do
    publish(note_written)
    other = create(:tenant)
    event = ActsAsTenant.with_tenant(other) { @event_store.read.stream(@stream).to_a.sole }

    ActsAsTenant.with_tenant(other) do
      assert_raises(PlanKeyStore::ForeignTenant) { event.data[:note].reveal }
    end
  end

  should "open a damaged field as removed" do
    damaged = Shreddable::Value::Sealed.new(ciphertext: "not base64!", iv: "AAAA", identifier: "x", cipher: "aes-256-gcm",
                                            key_of: ->(*) { flunk "no key lookup for a damaged field" })

    assert_predicate damaged, :removed?
  end

  should "refuse a shreddable write outside a transaction, so its key stays locked until the append" do
    PlanEncryptionKey.connection.stub(:transaction_open?, false) do
      assert_raises(ArgumentError) { publish(note_written) }
    end
  end

  should "write an event that declares nothing outside a transaction" do
    PlanEncryptionKey.connection.stub(:transaction_open?, false) do
      assert_nothing_raised { publish(Copied.new(data: { plan_id: @plan_id })) }
    end
  end

  should "encrypt the fields a parent class declares" do
    publish(SalaryNoteWritten.new(data: { plan_id: @plan_id, person_id: @person.id, note: "Moving to the platform team" }))

    assert_not_includes stored_row["data"].to_s, "platform team"
    assert_equal "Moving to the platform team", read_back.data[:note].reveal
  end

  should "refuse a declared field under a string key, which would store it in clear" do
    assert_raises(ArgumentError) { NoteWritten.new(data: { "plan_id" => @plan_id, "note" => "Moving to the platform team" }) }
  end

  should "read a value as removed when its key is destroyed after another from the same read was revealed" do
    publish(note_written)
    publish(note_written(note: "Joining the data team"))
    first, second = in_tenant { @event_store.read.stream(@stream).to_a }
    first.data[:note].reveal
    in_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }

    assert_predicate second.data[:note], :removed?
  end

  should "load a value that opened as removed back from Marshal as removed" do
    publish(note_written)
    note = read_back.data[:note]
    in_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }
    loaded = Marshal.load(Marshal.dump(note))

    assert_predicate loaded, :removed?
    assert_nil loaded.reveal
    assert_equal "[removed]", loaded.to_s
    assert_equal Shreddable::Value.removed.hash, loaded.hash
  end

  should "compare a value read back equal to the value written, either way round" do
    publish(note_written)
    written = Shreddable::Value.new("Moving to the platform team")
    read = read_back.data[:note]

    assert_equal written, read
    assert_equal read, written
    assert read.eql?(written)
    assert_equal written.hash, read.hash
  end

  should "keep a number read back eql? only to a number that hashes the same" do
    publish(note_written(note: { "hours" => 1, "split" => [ 2 ] }))
    read = read_back.data[:note]

    assert read.eql?(Shreddable::Value.new({ "hours" => 1, "split" => [ 2 ] }))
    assert_equal read, Shreddable::Value.new({ "hours" => 1.0, "split" => [ 2.0 ] })
    assert_not read.eql?(Shreddable::Value.new({ "hours" => 1.0, "split" => [ 2 ] }))
    assert_not read.eql?(Shreddable::Value.new({ "hours" => 1, "split" => [ 2.0 ] }))
    assert_equal 1, { read => true, Shreddable::Value.new({ "hours" => 1, "split" => [ 2 ] }) => true }.size
  end
end
