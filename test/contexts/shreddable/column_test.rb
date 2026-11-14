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
      live = stored

      PlanKeyStore.stub(:new, NoKeys.new) { rebuild }

      assert_equal live, stored, "a rebuild stored other bytes than the live write"
      assert_equal @event_store.read.of_type([ NoteWritten ]).last.data[:note].envelope, JSON.parse(stored)
      assert_equal NOTE, note.reveal
    end

    should "look up its key once however often a row reads it" do
      write_note
      ActsAsTenant.with_tenant(@tenant) do
        row = Note.find_by!(plan_id: @plan_id)
        assert_equal NOTE, row.note.reveal

        assert_no_queries { assert_equal NOTE, row.note.reveal }
      end
    end

    should "read as removed once the row moves to another plan, even if read before" do
      write_note
      ActsAsTenant.with_tenant(@tenant) do
        row = Note.find_by!(plan_id: @plan_id)
        row.note
        row.plan_id = SecureRandom.uuid_v7

        assert_predicate row.note, :removed?
      end
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

    should "seal a live value written into another plan's row under that row's key, which a rebuild can't repeat" do
      event = NoteWritten.new(data: { plan_id: @plan_id, note: NOTE })
      other_plan_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        Note.transaction do
          @event_store.with_metadata(tenant_id: @tenant.id) do
            @event_store.publish(event, stream_name: "tenant-#{@tenant.id}/PlanNotes-#{@plan_id}")
          end
          Note.create!(tenant_id: @tenant.id, plan_id: other_plan_id, note: event.data[:note])
        end
      end

      assert_equal NOTE, note(other_plan_id).reveal
      assert_equal PlanKeyStore.plan_identifier(@tenant.id, other_plan_id), JSON.parse(stored(other_plan_id))["identifier"]
    end

    should "seal a value for a write that skips the model" do
      write_note
      row = ActsAsTenant.with_tenant(@tenant) { Note.find_by!(plan_id: @plan_id) }
      Note.where(id: row.id).update_all(note: Note.seal_column(:note, "Staying put", tenant_id: @tenant.id, plan_id: @plan_id))

      assert_equal "Staying put", note.reveal
      assert_not_includes stored, "Staying"
    end

    should "in a rebuild, seal a value stored in clear before the field was shreddable as removed, once its key is gone" do
      destroy_key
      seal = -> { Note.transaction { Note.seal_column(:note, NOTE, tenant_id: @tenant.id, plan_id: @plan_id) } }

      assert_equal Shreddable::Column::REMOVED, Projections::Replayer.with_replay_mode(&seal)
      assert_raises(PlanKeyStore::Destroyed, "a live write after the key is gone", &seal)
    end

    should "seal a clear value again after a rollback, under a key that survived" do
      ActsAsTenant.with_tenant(@tenant) do
        row = Note.new(tenant_id: @tenant.id, plan_id: @plan_id, note: NOTE)
        Note.transaction(requires_new: true) do
          row.save!
          raise ActiveRecord::Rollback
        end
        row.save!
      end

      assert_equal NOTE, note.reveal
    end

    should "seal afresh a value whose publish rolled back, rather than copy it under the lost key" do
      event = NoteWritten.new(data: { plan_id: @plan_id, note: NOTE })
      ActsAsTenant.with_tenant(@tenant) do
        Note.transaction(requires_new: true) do
          @event_store.with_metadata(tenant_id: @tenant.id) do
            @event_store.publish(event, stream_name: "tenant-#{@tenant.id}/PlanNotes-#{@plan_id}")
          end
          raise ActiveRecord::Rollback
        end
        Note.create!(tenant_id: @tenant.id, plan_id: @plan_id, note: event.data[:note])
      end

      assert_equal NOTE, note.reveal
    end

    should "copy a value already in its stored form, and forget a clear one on reload or in a copy" do
      write_note
      ActsAsTenant.with_tenant(@tenant) do
        row = Note.find_by!(plan_id: @plan_id)
        copy = Note.create!(tenant_id: @tenant.id, plan_id: @plan_id, note: row.read_attribute(:note))
        assert_equal NOTE, copy.note.reveal

        twin = row.dup
        twin.note = "Staying put"
        assert_equal NOTE, row.note.reveal

        row.note = "Staying put"
        assert_equal NOTE, row.reload.note.reveal
      end
    end

    should "keep its declaration in a subclass" do
      write_note
      special = Class.new(Note)
      row = ActsAsTenant.with_tenant(@tenant) { special.find_by!(plan_id: @plan_id) }

      assert_equal NOTE, ActsAsTenant.with_tenant(@tenant) { row.note.reveal }
    end

    should "seal under the id ApplicationRecord gives a new row" do
      ids = Class.new(Note) { shreddable_column :note, by: :plan, plan: :id }
      ids.define_singleton_method(:name) { "PlanNamedById" }
      row = ActsAsTenant.with_tenant(@tenant) { ids.create!(tenant_id: @tenant.id, plan_id: @plan_id, note: NOTE) }

      assert_equal PlanKeyStore.plan_identifier(@tenant.id, row.id), JSON.parse(stored)["identifier"]
      assert_equal NOTE, ActsAsTenant.with_tenant(@tenant) { ids.find(row.id).note.reveal }
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
        -> { Note.where(plan_id: @plan_id).order(:note) },
        -> { Note.order(Note.arel_table[:note]) },
        -> { Note.order(Note.arel_table[:note].desc) },
        -> { Note.where(shreddable_column_test_notes: { note: NOTE }) },
        -> { Note.where.not("note IS NULL") },
        -> { Note.rewhere("note IS NULL") },
        -> { Note.group(:plan_id).having("count(note) > 0") },
        -> { Note.regroup(:note) },
        -> { Note.exists?([ "note->>'iv' = ?", NOTE ]) },
        -> { Class.new(Note).order(:note) }
      ].each_with_index { |query, i| assert_raises(Shreddable::Column::Refused, "query #{i}", &query) }
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
      assert_nothing_raised { Note.where([ "plan_id::text <> ?", "note" ]).to_a }
      assert_nothing_raised { Note.where.not([ "plan_id::text = ?", "note" ]).to_a }
      assert_nothing_raised { Note.exists?([ "plan_id::text = ?", "note" ]) }
      assert_nothing_raised { Note.rewhere([ "plan_id::text = ?", "note" ]).to_a }
      assert_nothing_raised { Note.select(:plan_id).group(:plan_id).having([ "min(plan_id::text) <> ?", "note" ]).to_a }
    end
  end
end
