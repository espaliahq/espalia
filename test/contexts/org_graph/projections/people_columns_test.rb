# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::PeopleColumnsTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  PROVENANCE = { provider: "espalia", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    as_tenant do
      @ada, @grace = create_list(:person, 2, tenant: @tenant, job_title: "Engineer")
    end
  end

  context "a tenant the HRIS sync still writes" do
    should "leave the row as the sync wrote it" do
      as_tenant do
        @handler.record_person(@ada.id, **PROVENANCE, employment_status: "left", title: "Designer", manager_id: @grace.id)
      end

      assert_equal [ "Engineer", nil, "active" ], columns(@ada)
    end

    should "leave the rows alone on reset" do
      OrgGraph::Projections::PeopleColumns.reset!(tenant: @tenant)

      assert_equal [ "Engineer", nil, "active" ], columns(@ada)
    end
  end

  context "a tenant cut over to the Org Graph" do
    setup { @tenant.update!(org_graph_people_projected_at: Time.current) }

    should "write for a request whose tenant was loaded before the cut-over" do
      stale = Tenant.find(@tenant.id).tap { it.org_graph_people_projected_at = nil }

      ActsAsTenant.with_tenant(stale) { @handler.record_person(@ada.id, **PROVENANCE, employment_status: "employed", title: "Designer") }

      assert_equal "Designer", columns(@ada).first
    end

    should "write the title, manager and status a person was recorded with" do
      as_tenant do
        @handler.record_person(@ada.id, **PROVENANCE, employment_status: "employed", title: "Designer", manager_id: @grace.id)
      end

      assert_equal [ "Designer", @grace.id, "active" ], columns(@ada)
    end

    should "count a hire who has not started as active" do
      as_tenant { @handler.record_person(@ada.id, **PROVENANCE, employment_status: "pending") }

      assert_equal "active", columns(@ada).last
    end

    should "follow each change, clearing a title or a manager the provider drops" do
      as_tenant do
        @handler.record_person(@ada.id, **PROVENANCE, employment_status: "employed", title: "Designer", manager_id: @grace.id)
        @handler.change_title(@ada.id, nil, **PROVENANCE)
        @handler.change_manager(@ada.id, nil, **PROVENANCE)
        @handler.leave(@ada.id, provider: "espalia", effective_on: "2026-03-01")
      end
      assert_equal [ nil, nil, "inactive" ], columns(@ada)

      as_tenant { @handler.return_to_work(@ada.id, provider: "espalia", effective_on: "2026-04-01") }
      assert_equal "active", columns(@ada).last
    end

    should "leave someone with no stream alone on reset, since no event would write them back" do
      as_tenant { @handler.record_person(@ada.id, **PROVENANCE, employment_status: "employed", title: "Designer") }

      OrgGraph::Projections::PeopleColumns.reset!(tenant: @tenant)

      assert_equal [ @ada.id ], OrgGraph::Projections::PeopleColumns.recorded_person_ids(@tenant)
      assert_nil columns(@ada).first
      assert_equal "Engineer", columns(@grace).first
    end

    should "rebuild the same columns from the streams" do
      as_tenant do
        @handler.record_person(@ada.id, **PROVENANCE, employment_status: "employed", title: "Designer", manager_id: @grace.id)
        @handler.record_person(@grace.id, **PROVENANCE, employment_status: "employed", title: "Lead")
        @handler.change_title(@ada.id, "Senior designer", **PROVENANCE)
        @handler.leave(@grace.id, provider: "espalia", effective_on: "2026-03-01")
      end
      before = snapshot_read_models(OrgGraph::Projections::PeopleColumns, @tenant)

      OrgGraph::Projections::PeopleColumns.reset!(tenant: @tenant)
      assert_equal [ nil, nil, "active" ], columns(@ada)
      Projections::Replayer.replay(projection_class: OrgGraph::Projections::PeopleColumns, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::PeopleColumns, @tenant)
      assert_equal [ "Senior designer", @grace.id, "active" ], columns(@ada)
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def columns(person)
    as_tenant { person.reload.slice(*OrgGraph::Projections::PeopleColumns::COLUMNS).values }
  end
end
