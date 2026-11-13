# frozen_string_literal: true

require "test_helper"

class Operations::Integrations::HrisLevelHandoverTest < ActiveSupport::TestCase
  FakeAdapter = Struct.new(:values, :fields) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = fields
    def read_field(_field_id, kind:, alongside: nil) = values
  end

  TEAM = Hris::Field.new(id: "work.team", name: "Team", kind: :list,
                         values: [ Hris::Field::Value.new(id: "7", name: "Payments"), Hris::Field::Value.new(id: "8", name: "Search") ])

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin)
      @member = create(:tenant_user, tenant: @tenant, role: :member)
      system = OrgGraph::Authorization::SYSTEM
      structure = OrgGraph::StructureCommandHandler.new(actor: system)
      @level_id = SecureRandom.uuid_v7
      structure.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
      structure.define_taxonomy([ { level_id: @level_id, name: "Team" } ], effective_on: "2026-01-01")
      @payments, @legacy = %w[Payments Legacy].map do |name|
        SecureRandom.uuid_v7.tap { structure.create_unit(it, name, level_id: @level_id, effective_on: "2026-01-01") }
      end
      @person = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-1", name: "Rin Reader")
      people = OrgGraph::CommandHandler.new(actor: system)
      people.record_person(@person.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed")
      people.set_membership(@person.id, @payments, provider: "espalia", effective_on: "2026-11-01")
    end
    @adapter = FakeAdapter.new({ "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments") }, [ TEAM ])
    @matches = { @payments => "7" }
    @resolutions = { @legacy => "retire" }
  end

  def call(operation, tenant_user: @admin, **params)
    Hris::BaseAdapter.stub(:for, @adapter) do
      ActsAsTenant.with_tenant(@tenant) do
        operation.call(context: AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil),
                       params: { level_id: @level_id, **params })
      end
    end
  end

  def compare(**params) = call(Operations::Integrations::HrisLevelHandover, field_id: TEAM.id, **params)

  context "the comparison" do
    should "suggest a value by name, leave every unit unresolved, and name nobody" do
      result = compare

      assert_equal "hand_over", result[:direction]
      assert_equal({ key: "7", label: "Payments" }, result[:units].find { it[:name] == "Payments" }[:suggestion])
      assert_equal %w[Legacy Payments], result[:unresolved].sort
      assert_not_includes result.to_json, "Rin Reader"
    end

    should "need a field to hand a level over" do
      assert_raises(Operations::Base::ParameterError) { call(Operations::Integrations::HrisLevelHandover) }
    end

    should "refuse a member" do
      assert_raises(Pundit::NotAuthorizedError) { compare(tenant_user: @member) }
    end
  end

  context "handing over" do
    should "switch the level on the comparison's fingerprint" do
      fingerprint = compare(matches: @matches, resolutions: @resolutions)[:fingerprint]

      call(Operations::Integrations::HandOverHrisLevel, field_id: TEAM.id, matches: @matches, resolutions: @resolutions, fingerprint:)

      assert_equal "hibob", ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.find(@level_id).provider }
    end

    should "refuse a fingerprint nobody was shown" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::Integrations::HandOverHrisLevel, field_id: TEAM.id, matches: @matches, resolutions: @resolutions,
                                                         fingerprint: "0000000000000000")
      end

      assert_match(/compare again/, error.message)
    end

    should "need approval in the app" do
      assert_equal :in_app, Operations::Integrations::HandOverHrisLevel.approval
      assert_equal :in_app, Operations::Integrations::HandBackHrisLevel.approval
    end
  end

  context "handing back" do
    should "hand the level back on the hand-back comparison's fingerprint, saying what it keeps" do
      fingerprint = compare(matches: @matches, resolutions: @resolutions)[:fingerprint]
      call(Operations::Integrations::HandOverHrisLevel, field_id: TEAM.id, matches: @matches, resolutions: @resolutions, fingerprint:)
      handback = call(Operations::Integrations::HrisLevelHandover)

      result = call(Operations::Integrations::HandBackHrisLevel, fingerprint: handback[:fingerprint])

      assert_equal [ "hand_back", 1, 1 ], result.values_at(:direction, :units, :memberships)
      assert_equal "espalia", ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.find(@level_id).provider }
      assert_match(/successions and retirements made by the handover stand/,
                   Operations::Integrations::HandBackHrisLevel.description)
    end

    should "hand the level back after the HRIS is disconnected" do
      fingerprint = compare(matches: @matches, resolutions: @resolutions)[:fingerprint]
      call(Operations::Integrations::HandOverHrisLevel, field_id: TEAM.id, matches: @matches, resolutions: @resolutions, fingerprint:)
      @tenant.disconnect_hris!

      Hris::BaseAdapter.stub(:for, ->(*) { flunk "hand-back built an HRIS adapter" }) do
        ActsAsTenant.with_tenant(@tenant) do
          context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: nil)
          handback = Operations::Integrations::HrisLevelHandover.call(context:, params: { level_id: @level_id })
          Operations::Integrations::HandBackHrisLevel.call(context:, params: { level_id: @level_id, fingerprint: handback[:fingerprint] })
        end
      end

      assert_equal "espalia", ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.find(@level_id).provider }
    end
  end
end
