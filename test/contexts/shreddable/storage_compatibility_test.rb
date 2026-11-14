# frozen_string_literal: true

require "test_helper"

# Events that declare nothing must store and read exactly as before the
# shreddable mapper, with no query and no key lookup. The fixture holds one
# stored record of each event type the seeds, the Org Graph fixture and the
# plan handler write, from every context.
class Shreddable::StorageCompatibilityTest < ActiveSupport::TestCase
  class RefusingKeyStore
    def method_missing(name, *) = raise("The key store was called: #{name}")
    def respond_to_missing?(*) = true
  end

  FIXTURE = Rails.root.join("test/fixtures/files/event_store/records.json")

  setup do
    @default = Shreddable::Mapper.json_client_default
    @shreddable = Shreddable::Mapper.new(@default, key_store: RefusingKeyStore.new)
    @records = JSON.parse(FIXTURE.read).map do |row|
      RubyEventStore::SerializedRecord.new(
        event_id: row["event_id"], event_type: row["event_type"], data: row["data"], metadata: row["metadata"],
        timestamp: row["created_at"], valid_at: row["valid_at"] || row["created_at"]
      )
    end
  end

  def read(mapper, record) = mapper.records_to_events([ record.deserialize(JSON) ]).sole

  def write(mapper, event) = mapper.events_to_records([ event ]).sole.serialize(JSON)

  should "cover every context" do
    contexts = @records.map { it.event_type.split("::").first }.uniq.sort

    assert_equal %w[AssessmentCycles Frameworks OrgGraph PersonDevelopment TeamPlanning], contexts
  end

  should "read every stored record as the default mapper does" do
    @records.each do |record|
      expected = read(@default, record)
      actual = read(@shreddable, record)

      assert_equal [ expected.class, expected.event_id, expected.data, expected.metadata.to_h ],
                   [ actual.class, actual.event_id, actual.data, actual.metadata.to_h ], record.event_type
    end
  end

  should "write every event byte for byte as the default mapper does" do
    @records.each do |record|
      event = read(@default, record)
      expected = write(@default, event)
      actual = write(@shreddable, event)

      assert_equal [ expected.data, expected.metadata ], [ actual.data, actual.metadata ], record.event_type
      assert_equal [ record.data, record.metadata ], [ actual.data, actual.metadata ], record.event_type
    end
  end

  should "run no query and call no key store for events that declare nothing" do
    events = @records.map { read(@default, it) }
    serialized = @records.map { it.deserialize(JSON) }

    assert_no_queries do
      @shreddable.events_to_records(events)
      @shreddable.records_to_events(serialized)
    end
  end
end
