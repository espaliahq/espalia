# frozen_string_literal: true

require "test_helper"

class OrgGraph::FactConfirmationTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-11-01" }.freeze
  HIBOB = { provider: "hibob", effective_on: "2026-11-01" }.freeze

  setup do
    @aggregate = OrgGraph::PersonAggregate.new
    @person_id = SecureRandom.uuid_v7
    @confirmer_id = SecureRandom.uuid_v7
    @unit_id = SecureRandom.uuid_v7
    @aggregate.record(@person_id, **HIBOB, employment_status: "employed", title: "Engineer")
  end

  def confirm(fact, **options)
    @aggregate.confirm_fact(fact, confirmed_by_id: @confirmer_id, effective_on: "2026-11-10", **options)
  end

  def confirmations
    @aggregate.unpublished_events.grep(OrgGraph::Events::FactConfirmed)
  end

  should "confirm a membership Espalia holds, naming the unit and who confirmed it, and no value" do
    @aggregate.set_membership(@unit_id, **ESPALIA, allocation: 0.5, role: "Tech lead")
    confirm(:membership, unit_id: @unit_id.upcase)

    data = confirmations.sole.data
    assert_equal({ person_id: @person_id, provider: "espalia", effective_on: "2026-11-10", fact: "membership",
                   unit_id: @unit_id, confirmed_by_id: @confirmer_id }, data)
  end

  should "confirm a person fact Espalia holds" do
    @aggregate.change_manager(SecureRandom.uuid_v7, **ESPALIA)
    confirm(:manager_id)

    assert_equal [ "manager_id", nil ], confirmations.sole.data.values_at(:fact, :unit_id)
  end

  should "refuse a fact another provider holds, and write nothing" do
    @aggregate.set_membership(@unit_id, **HIBOB)

    assert_raises(RuntimeError, match: /Espalia holds/) { confirm(:title) }
    assert_raises(RuntimeError, match: /Espalia holds/) { confirm(:membership, unit_id: @unit_id) }
    assert_empty confirmations
  end

  should "refuse a fact the person doesn't have" do
    @aggregate.change_title(nil, **ESPALIA)

    assert_raises(RuntimeError, match: /Espalia holds/) { confirm(:title) }
    assert_raises(RuntimeError, match: /Not a member/) { confirm(:membership, unit_id: @unit_id) }
  end

  should "refuse an unknown fact, a membership with no unit, and a unit on another fact" do
    assert_raises(RuntimeError, match: /Unknown fact/) { confirm(:email) }
    assert_raises(RuntimeError, match: /UUID/) { confirm(:membership) }
    assert_raises(RuntimeError, match: /names a unit/) { confirm(:title, unit_id: @unit_id) }
  end

  should "refuse without a confirmer, for a leaver, and before the person is recorded" do
    @aggregate.change_title("Lead", **ESPALIA)
    assert_raises(RuntimeError, match: /Confirmed by/) do
      @aggregate.confirm_fact(:title, confirmed_by_id: nil, effective_on: "2026-11-10")
    end

    @aggregate.leave(**HIBOB)
    assert_raises(RuntimeError, match: /has left/) { confirm(:title) }

    assert_raises(RuntimeError) do
      OrgGraph::PersonAggregate.new.confirm_fact(:title, confirmed_by_id: @confirmer_id, effective_on: "2026-11-10")
    end
  end

  should "leave the facts as they were" do
    @aggregate.change_title("Lead", **ESPALIA)
    confirm(:title)

    @aggregate.change_title("Lead", **ESPALIA)
    assert_equal 1, @aggregate.unpublished_events.grep(OrgGraph::Events::TitleChanged).size
  end

  should "write the confirmation to the person's stream through the command handler" do
    tenant = create(:tenant)
    ActsAsTenant.with_tenant(tenant) do
      handler = OrgGraph::CommandHandler.new
      handler.record_person(@person_id, **ESPALIA, employment_status: "employed", title: "Engineer")
      handler.confirm_fact(@person_id, "title", confirmed_by_id: @confirmer_id, effective_on: "2026-11-10")
    end

    event = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(@person_id, tenant: tenant)).last
    assert_instance_of OrgGraph::Events::FactConfirmed, event
    assert_equal tenant.id, event.metadata[:tenant_id]
  end
end
