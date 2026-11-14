# frozen_string_literal: true

require "test_helper"

class Shreddable::AggregateRootTest < ActiveSupport::TestCase
  class NoteWritten < RubyEventStore::Event
    extend Shreddable
    shreddable :note, by: :plan
  end

  class Notebook
    include Shreddable::AggregateRoot

    attr_reader :seen

    def write(plan_id, note) = apply(NoteWritten.new(data: { plan_id: plan_id, note: note }))

    on NoteWritten do |event|
      (@seen ||= []) << event.data[:note]
    end
  end

  setup do
    @tenant = create(:tenant)
    @plan_id = SecureRandom.uuid_v7
    @event_store = Rails.configuration.event_store
    @repository = AggregateRoot::Repository.new(@event_store)
    @stream = "tenant-#{@tenant.id}/ShreddableNotebook-#{@plan_id}"
  end

  def in_tenant(&) = ActsAsTenant.with_tenant(@tenant) { @event_store.with_metadata(tenant_id: @tenant.id, &) }

  def write_note
    in_tenant { @repository.with_aggregate(Notebook.new, @stream) { it.write(@plan_id, "Moving to the platform team") } }
  end

  def replayed = in_tenant { @repository.load(Notebook.new, @stream) }

  should "hand the handler the placeholder for an event it applies" do
    notebook = Notebook.new
    notebook.write(@plan_id, "Moving to the platform team")

    assert_equal [ Shreddable::Value.removed ], notebook.seen
    assert_equal "Moving to the platform team", notebook.unpublished_events.first.data[:note].reveal
  end

  should "hand the handler the placeholder on replay, with the key and without it" do
    write_note
    with_key = replayed.seen
    in_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }

    assert_equal [ Shreddable::Value.removed ], with_key
    assert_equal with_key, replayed.seen
  end

  should "publish the real event to subscribers, never the redacted copy" do
    seen = []
    @event_store.within { write_note }.subscribe(->(event) { seen << event.data[:note] }, to: [ NoteWritten ]).call

    assert_equal "Moving to the platform team", seen.sole.reveal
  end

  should "pass an event that declares nothing to its handler as it is" do
    event = RubyEventStore::Event.new(data: { plan_id: @plan_id })

    assert_same event, Shreddable.redact(event)
  end

  should "redact before an aggregate's own strategy applies the event" do
    seen = nil
    strategy = Shreddable::RedactingApplyStrategy.new(->(_aggregate, event) { seen = event.data[:note] })

    strategy.call(Object.new, NoteWritten.new(data: { plan_id: @plan_id, note: "Ask about the move" }))

    assert_predicate seen, :removed?
  end

  should "be the base of every aggregate in the app" do
    Rails.application.eager_load!
    aggregates = ObjectSpace.each_object(Class).select do |klass|
      klass < AggregateRoot::AggregateMethods && Object.const_source_location(klass.name)&.first&.start_with?(Rails.root.join("app").to_s)
    end

    assert_operator aggregates.size, :>=, 7
    aggregates.each do |klass|
      assert_kind_of Shreddable::RedactingApplyStrategy, klass.allocate.send(:apply_strategy), "#{klass} includes plain AggregateRoot"
    end
  end
end
