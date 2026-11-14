# frozen_string_literal: true

require "test_helper"

# A read-model column that copies a shreddable field keeps it sealed, so a
# destroyed key reaches the copy at once, and a rebuild needs no key.
class Shreddable::ColumnTest < ActiveSupport::TestCase
  NOTE = "Moving to the platform team"

  class NoteWritten < RubyEventStore::Event
    extend Shreddable
    shreddable :note, by: :plan
  end

  class Note < ApplicationRecord
    include Shreddable::Column

    self.table_name = "shreddable_column_test_notes"
    shreddable_column :note, by: :plan
  end

  class Notes
    def self.handled_events = [ NoteWritten ]

    def call(event)
      ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
        Note.find_or_initialize_by(plan_id: event.data[:plan_id])
          .update!(tenant_id: event.metadata[:tenant_id], note: event.data[:note])
      end
    end
  end

  # Fails the test if anything mints or looks up a key.
  class NoKeys
    def method_missing(name, *) = raise("Looked up a key: #{name}")
    def respond_to_missing?(*) = true
  end

  setup do
    Note.connection.create_table(:shreddable_column_test_notes, id: :uuid, temporary: true) do |t|
      t.uuid :tenant_id, null: false
      t.uuid :plan_id, null: false
      t.jsonb :note
    end
    Note.reset_column_information
    @tenant = create(:tenant)
    @plan_id = SecureRandom.uuid_v7
    @event_store = Rails.configuration.event_store
    @unsubscribe = @event_store.subscribe(Notes.new, to: Notes.handled_events)
  end

  teardown { @unsubscribe&.call }

  def write_note(plan_id = @plan_id)
    ActsAsTenant.with_tenant(@tenant) do
      @event_store.with_metadata(tenant_id: @tenant.id) do
        @event_store.publish(NoteWritten.new(data: { plan_id: plan_id, note: NOTE }), stream_name: "tenant-#{@tenant.id}/PlanNotes-#{plan_id}")
      end
    end
  end

  def note(plan_id = @plan_id)
    ActsAsTenant.with_tenant(@tenant) { Note.find_by!(plan_id: plan_id).note.tap { it.removed? } }
  end

  def stored(plan_id = @plan_id)
    Note.connection.select_value(Note.sanitize_sql_array([ "SELECT note::text FROM shreddable_column_test_notes WHERE plan_id = ?", plan_id ]))
  end

  def destroy_key = ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_plan(@plan_id) }

  def rebuild
    Note.delete_all
    Projections::Replayer.replay(projection_class: Notes, tenant: @tenant)
  end

  context "a shreddable column" do
    should "keep the value from the live write, and hold no clear text at rest" do
      write_note

      assert_equal NOTE, note.reveal
      assert_not_includes stored, "platform"
      assert_equal %w[cipher ciphertext identifier iv], JSON.parse(stored).keys.sort
    end

    should "read as removed once the key is destroyed, with no rebuild" do
      write_note
      destroy_key

      assert_predicate note, :removed?
    end

    should "rebuild after the key is destroyed, writing a removed value and raising nothing" do
      write_note
      destroy_key

      assert_nothing_raised { rebuild }
      assert_predicate note, :removed?
      assert_not_includes stored, "platform"
    end

    should "rebuild by copying the event's sealed value, without looking up a key" do
      write_note
      sealed = @event_store.read.of_type([ NoteWritten ]).last.data[:note].envelope

      PlanKeyStore.stub(:new, NoKeys.new) { rebuild }

      assert_equal sealed, JSON.parse(stored)
      assert_equal NOTE, note.reveal
    end

    should "read as removed when it holds another row's sealed value" do
      write_note
      other_plan_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        Note.create!(tenant_id: @tenant.id, plan_id: other_plan_id, note: Note.find_by!(plan_id: @plan_id).note)
      end

      assert_predicate note(other_plan_id), :removed?
      assert_equal NOTE, note.reveal
    end

    should "seal a value for a write that skips the model" do
      write_note
      row = ActsAsTenant.with_tenant(@tenant) { Note.find_by!(plan_id: @plan_id) }
      Note.where(id: row.id).update_all(note: Note.seal_column(:note, "Staying put", tenant_id: @tenant.id, plan_id: @plan_id))

      assert_equal "Staying put", note.reveal
      assert_not_includes stored, "Staying"
    end

    should "refuse to order, match, group or pluck it" do
      [
        -> { Note.order(:note) },
        -> { Note.order(note: :desc) },
        -> { Note.order("note DESC") },
        -> { Note.reorder("shreddable_column_test_notes.note") },
        -> { Note.where(note: NOTE) },
        -> { Note.where("note->>'x' = ?", NOTE) },
        -> { Note.group(:note) },
        -> { Note.pluck(:note) },
        -> { Note.pick(:note) },
        -> { Note.where(plan_id: @plan_id).order(:note) }
      ].each { assert_raises(Shreddable::Column::Refused, &it) }
    end

    should "refuse a value in clear on a write that skips the model" do
      assert_raises(Shreddable::Column::Refused) { Note.update_all(note: NOTE) }
      assert_raises(Shreddable::Column::Refused) do
        Note.insert_all!([ { tenant_id: @tenant.id, plan_id: @plan_id, note: NOTE } ])
      end
    end

    should "allow queries on other columns, even with a value that reads like its name" do
      write_note

      assert_equal 1, Note.where("plan_id = ?", @plan_id).order(:plan_id).count
      assert_equal [ @plan_id ], Note.where(plan_id: @plan_id).pluck(:plan_id)
      assert_nothing_raised { Note.where(plan_id: "note").to_a }
    end
  end
end
