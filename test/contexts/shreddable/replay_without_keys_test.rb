# frozen_string_literal: true

require "test_helper"

# Destroying every plan key must change nothing an aggregate decides, and no
# projection rebuild may raise. Streams come from every context, built
# through the real command handlers.
class Shreddable::ReplayWithoutKeysTest < ActiveSupport::TestCase
  include OrgGraphFixture
  include RoleLensFixture

  class NoteWritten < RubyEventStore::Event
    extend Shreddable
    shreddable :note, by: :plan
  end

  # Decides from the note, so replay would differ if it ever saw the value.
  class Notebook
    include Shreddable::AggregateRoot

    on NoteWritten do |event|
      (@notes ||= []) << [ event.data[:note].removed?, event.data[:note].to_s, event.data[:note].reveal ]
    end
  end

  AGGREGATES = {
    %r{/PlanNotes-} => Notebook,
    %r{/Framework-} => Frameworks::Aggregate,
    %r{/PersonDev-} => PersonDevelopment::Aggregate,
    %r{/AssessmentCycle-} => AssessmentCycles::Aggregate,
    %r{/CalibrationSession-} => AssessmentCycles::CalibrationSessionAggregate,
    %r{/Person-} => OrgGraph::PersonAggregate,
    %r{/OrgStructure\z} => OrgGraph::StructureAggregate,
    %r{/Plan-} => TeamPlanning::PlanAggregate
  }.freeze

  setup do
    @tenant = create(:tenant)
    @event_store = Rails.configuration.event_store
    build_org_graph(@tenant)
    @other_tenant = create(:tenant)
    write_note(@other_tenant, SecureRandom.uuid_v7)
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.create_framework(SecureRandom.uuid_v7, "Engineering Growth")
      enrol_in_role_lens_framework(create(:person, tenant: @tenant), build_role_lens_framework(tenant: @tenant), tenant: @tenant)
      person = create(:person, tenant: @tenant)
      user = create(:user)
      admin = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, person:, role: :admin), person:)
      @plan_id = SecureRandom.uuid_v7
      TeamPlanning::CommandHandler.new(actor: admin).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
    end
    write_note(@tenant, @plan_id)
  end

  def write_note(tenant, plan_id)
    ActsAsTenant.with_tenant(tenant) do
      @event_store.with_metadata(tenant_id: tenant.id) do
        @event_store.publish(NoteWritten.new(data: { plan_id: plan_id, note: "Moving to the platform team" }),
                             stream_name: "tenant-#{tenant.id}/PlanNotes-#{plan_id}")
      end
    end
  end

  def streams
    ActiveRecord::Base.connection.select_values(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE ?",
                                              "tenant-#{@tenant.id}/%" ])
    )
  end

  def replay_every_aggregate
    repository = AggregateRoot::Repository.new(@event_store)
    ActsAsTenant.with_tenant(@tenant) do
      streams.filter_map do |stream|
        aggregate = AGGREGATES.find { |pattern, _| stream.match?(pattern) }&.last or next
        # Marshal also refuses any value still in clear.
        [ stream, Marshal.dump(repository.load(aggregate.new, stream).marshal_dump) ]
      end.sort_by(&:first)
    end
  end

  def destroy_every_key
    ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_plan(@plan_id) }
    assert_empty PlanEncryptionKey.unscoped.live.where(tenant: @tenant)
  end

  should "replay every aggregate to the same state once every key is destroyed" do
    with_keys = replay_every_aggregate
    destroy_every_key

    assert_equal AGGREGATES.values.sort_by(&:name) - [ AssessmentCycles::CalibrationSessionAggregate ],
                 with_keys.map { |stream, _| AGGREGATES.find { |pattern, _| stream.match?(pattern) }.last }.uniq.sort_by(&:name)
    assert_equal with_keys, replay_every_aggregate
  end

  should "rebuild every projection once every key is destroyed" do
    destroy_every_key

    assert_nothing_raised { Projections::GlobalReplayer.replay_all(tenant: @tenant) }
  end

  should "read the whole store under one tenant, as the replayers do, past another tenant's shreddable events" do
    destroy_every_key

    ActsAsTenant.with_tenant(@tenant) do
      events = assert_nothing_raised { @event_store.read.of_type([ NoteWritten ]).to_a }
      assert_equal [ @tenant.id, @other_tenant.id ].sort, events.map { it.metadata[:tenant_id] }.sort
    end
  end
end
