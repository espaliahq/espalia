# frozen_string_literal: true

# The worked example on #537. Engineering declares a structure of Groups and
# Teams. Commerce is a Group under it; Payments and Billing are Teams under
# Commerce. Priya owns Payments, Sam manages Priya and Lee manages Sam. Dana
# owns Commerce. Kim reports to Dana and sits in Payments. Omar is an Org
# Graph editor and Ana a tenant admin.
module OrgGraphRightsExample
  SYSTEM = OrgGraph::Authorization::SYSTEM
  ON = "2026-01-01"

  def build_rights_example
    @tenant = create(:tenant)
    @system = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @department, @group, @team = Array.new(3) { SecureRandom.uuid_v7 }
    @engineering, @commerce, @payments, @billing = Array.new(4) { SecureRandom.uuid_v7 }

    as_tenant do
      @system.define_taxonomy([ { level_id: @department, name: "Department" } ], effective_on: ON)
      @system.create_unit(@engineering, "Engineering", level_id: @department, effective_on: ON)
      admin_handler.declare_structure(@engineering, levels: [ { level_id: @group, name: "Group", parent_level_ids: [], top: true },
                                                              { level_id: @team, name: "Team", parent_level_ids: [ @group ], top: false } ],
                                                    conversion: {}, effective_on: ON)
      @system.create_unit(@commerce, "Commerce", level_id: @group, parent_id: @engineering, effective_on: ON)
      @system.create_unit(@payments, "Payments", level_id: @team, parent_id: @commerce, effective_on: ON)
      @system.create_unit(@billing, "Billing", level_id: @team, parent_id: @commerce, effective_on: ON)

      @lee = person("Lee")
      @sam = person("Sam", manager: @lee)
      @priya = person("Priya", manager: @sam)
      @dana = person("Dana")
      @kim = person("Kim", manager: @dana)
      @omar = person("Omar")
      @ana = person("Ana")
      @system.add_unit_owner(@payments, @priya.id, effective_on: ON)
      @system.add_unit_owner(@commerce, @dana.id, effective_on: ON)
      people_handler(SYSTEM).set_membership(@kim.id, @payments, provider: "espalia", effective_on: ON, allocation: 1.0)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  # @param person [Person]
  def context_for(person, role: :member, org_graph_editor: false)
    tenant_user = as_tenant { create(:tenant_user, tenant: @tenant, person:, role:, org_graph_editor:) }
    AuthorizationContext.new(user: tenant_user.user, tenant_user:, person:)
  end

  def omar_context = @omar_context ||= context_for(@omar, org_graph_editor: true)

  def ana_context = @ana_context ||= context_for(@ana, role: :admin)

  def unit(id) = as_tenant { OrgUnit.find(id) }

  def structure_handler(actor) = OrgGraph::StructureCommandHandler.new(actor:)

  def people_handler(actor) = OrgGraph::CommandHandler.new(actor:)

  private

  def admin_handler
    @admin_handler ||= structure_handler(AuthorizationContext.new(user: nil, tenant_user: create(:tenant_user, tenant: @tenant, role: :admin), person: nil))
  end

  def person(name, manager: nil)
    create(:person, tenant: @tenant, name:, manager:).tap do |person|
      people_handler(SYSTEM).record_person(person.id, provider: "espalia", effective_on: ON, employment_status: "employed")
    end
  end
end
