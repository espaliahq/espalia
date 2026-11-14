# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::SourcesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant, :with_hibob_config)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin)
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true)
      @member = create(:tenant_user, tenant: @tenant, role: :member)
      @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      @department, @team, @empty = Array.new(3) { SecureRandom.uuid_v7 }
      @structure.define_taxonomy([ { level_id: @department, name: "Department", provider: "hibob" },
                                   { level_id: @empty, name: "Region" }, { level_id: @team, name: "Team" } ],
                                 effective_on: "2026-01-01")
      @structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: @team, effective_on: "2026-01-01")
      @structure.set_fact_provider("cost_centre", "hibob", fields: { cost_centre: "work.customColumns.column_1" },
                                                           effective_on: "2026-01-01")
    end
  end

  def call(operation = Operations::OrgGraph::Sources, tenant_user: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil), params:)
    end
  end

  context "Sources" do
    should "list every fact with its provider and fields, Espalia's where nobody chose" do
      facts = call[:facts].index_by { it[:fact] }

      assert_equal OrgGraph::StructureAggregate::FACTS, call[:facts].pluck(:fact)
      assert_equal [ "hibob", { "cost_centre" => "work.customColumns.column_1" }, [ "cost_centre" ] ],
        facts["cost_centre"].values_at(:provider, :fields, :mappable_parts)
      assert_equal [ "espalia", {} ], facts["title"].values_at(:provider, :fields)
    end

    should "list the levels top first with their provider, field and live units" do
      levels = call[:levels]

      assert_equal %w[Department Region Team], levels.pluck(:name)
      assert_equal %w[hibob espalia espalia], levels.pluck(:provider)
      assert_equal [ 0, 0, 1 ], levels.pluck(:live_units)
    end

    should "name the retired units each level held, so the panel knows which it can't remove" do
      ActsAsTenant.with_tenant(@tenant) do
        [ "Billing", "Atlas", "Billing", "Cobalt", "Delta" ].each do |name|
          unit_id = SecureRandom.uuid_v7
          @structure.create_unit(unit_id, name, level_id: @empty, effective_on: "2026-01-01")
          @structure.retire_unit(unit_id, effective_on: "2026-02-01")
        end
      end

      levels = call[:levels]
      assert_equal [ 0, 4, 0 ], levels.pluck(:retired_units)
      assert_equal [ [], %w[Atlas Billing Cobalt], [] ], levels.pluck(:retired_unit_names)
    end

    should "call a level removable only when Espalia holds it, no unit ever held it and another level stays" do
      assert_equal [ false, true, false ], call[:levels].pluck(:removable)
    end

    should "keep the only level" do
      tenant = create(:tenant)
      levels = ActsAsTenant.with_tenant(tenant) do
        admin = create(:tenant_user, tenant:, role: :admin)
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .define_taxonomy([ { level_id: SecureRandom.uuid_v7, name: "Team" } ],
                                                          effective_on: "2026-01-01")
        Operations::OrgGraph::Sources.call(context: AuthorizationContext.new(user: admin.user, tenant_user: admin, person: nil),
                                           params: {})[:levels]
      end

      assert_equal [ false ], levels.pluck(:removable)
    end

    should "say which HRIS is connected, and count stale facts against the threshold" do
      result = call

      assert_equal({ provider: "hibob", label: "HiBob", connected: true }, result[:hris])
      assert_equal({ staleness_days: 90, stale: 0, stale_by_fact: {} }, result[:freshness])
    end

    should "count each fact Espalia holds that nobody changed or confirmed within the threshold" do
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant)
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          .record_person(person.id, provider: "espalia", effective_on: "2026-01-01", employment_status: "employed", title: "Engineer")
      end
      @tenant.update!(org_graph_config: { staleness_days: 30 })

      travel 31.days do
        freshness = call[:freshness]
        assert_equal [ 30, 1, { "title" => 1 } ], freshness.values_at(:staleness_days, :stale, :stale_by_fact)
      end
    end

    should "be open to an Org Graph editor and closed to other members" do
      assert call(tenant_user: @editor)[:facts]
      assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member) }
    end
  end

  context "SetFactProvider" do
    should "hand a fact to the connected HRIS with its fields, then back to Espalia, clearing them" do
      result = call(Operations::OrgGraph::SetFactProvider, fact: "site", provider: "hibob", fields: { "country" => "address.country" })
      assert_equal({ fact: "site", provider: "hibob", fields: { "country" => "address.country" } }, result)

      assert_equal({ fact: "site", provider: "espalia", fields: {} },
                   call(Operations::OrgGraph::SetFactProvider, fact: "site", provider: "espalia"))
    end

    should "keep a fact's fields when its provider is restated without them" do
      call(Operations::OrgGraph::SetFactProvider, fact: "cost_centre", provider: "hibob")

      assert_equal({ "cost_centre" => "work.customColumns.column_1" },
                   ActsAsTenant.with_tenant(@tenant) { OrgFactProvider.find_by(fact: "cost_centre").fields })
    end

    should "let a bug inside the aggregate surface as itself, not as a parameter error" do
      broken = Object.new
      def broken.set_fact_provider(*, **) = raise(FrozenError, "can't modify frozen Hash")

      OrgGraph::StructureCommandHandler.stub(:new, broken) do
        assert_raises(FrozenError) { call(Operations::OrgGraph::SetFactProvider, fact: "site", provider: "espalia") }
      end
    end

    should "refuse an HRIS the tenant hasn't connected, a part no field can supply, and an unknown fact" do
      @tenant.disconnect_hris!
      assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::SetFactProvider, fact: "title", provider: "hibob") }
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetFactProvider, fact: "title", provider: "espalia", fields: { "country" => "x" })
      end
      assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::SetFactProvider, fact: "shoe_size", provider: "espalia") }
    end

    should "refuse a member who is not an Org Graph editor" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::OrgGraph::SetFactProvider, tenant_user: @member, fact: "title", provider: "hibob")
      end
    end
  end

  context "SetLevelProvider" do
    should "hand an empty level to the connected HRIS with its field, and back" do
      result = call(Operations::OrgGraph::SetLevelProvider, level_id: @empty, provider: "hibob", field: "work.region")
      assert_equal [ "hibob", "work.region" ], result.values_at(:provider, :field)

      result = call(Operations::OrgGraph::SetLevelProvider, level_id: @empty, provider: "espalia")
      assert_equal [ "espalia", nil ], result.values_at(:provider, :field)
    end

    should "send a level that holds live units to the handover" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetLevelProvider, level_id: @team, provider: "hibob", field: "work.team")
      end

      assert_match(/hand it over/, error.message)
    end

    should "refuse an HRIS level with no field to read its units from" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetLevelProvider, level_id: @empty, provider: "hibob")
      end

      assert_match(/field/, error.message)
      assert_equal "espalia", OrgTaxonomyLevel.find(@empty).provider
    end

    should "refuse an unknown level, and a field for Espalia" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetLevelProvider, level_id: SecureRandom.uuid_v7, provider: "espalia")
      end
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetLevelProvider, level_id: @empty, provider: "espalia", field: "work.region")
      end
    end

    should "refuse a member who is not an Org Graph editor" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::OrgGraph::SetLevelProvider, tenant_user: @member, level_id: @empty, provider: "espalia")
      end
    end
  end
end
