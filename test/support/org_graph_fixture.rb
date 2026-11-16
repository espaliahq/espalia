# frozen_string_literal: true

# An invented organisation, built through the Org Graph's command handlers so
# its read models come from the real projections:
#
#   Engineering (department, from the HRIS)
#     Platform (team): Ada Quill, Brook Tamsin at half
#     Checkout (team): Brook Tamsin at half, Cyril Moss
#       Payments (squad): Dot Fennick
#
# Ezra Pell is active and in no unit; Faye Lumen is inactive and in none.
module OrgGraphFixture
  PROVENANCE = { provider: "espalia", effective_on: "2026-01-05" }.freeze

  # @param tenant [Tenant]
  # @return [Hash{Symbol => String, Person}] unit ids and people by name
  def build_org_graph(tenant)
    ids = %i[department team squad engineering platform checkout payments].index_with { SecureRandom.uuid_v7 }
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)

    ActsAsTenant.with_tenant(tenant) do
      structure.define_taxonomy([
        { level_id: ids[:department], name: "Department", provider: "hibob" },
        { level_id: ids[:team], name: "Team" },
        { level_id: ids[:squad], name: "Squad" }
      ], effective_on: "2026-01-01")
      structure.create_unit(ids[:engineering], "Engineering", level_id: ids[:department], provider: "hibob",
                                                              external_ref: "dept-100", effective_on: "2026-01-01")
      structure.create_unit(ids[:platform], "Platform", level_id: ids[:team], parent_id: ids[:engineering],
                                                        effective_on: "2026-01-01")
      structure.create_unit(ids[:checkout], "Checkout", level_id: ids[:team], parent_id: ids[:engineering],
                                                        effective_on: "2026-01-01")
      structure.create_unit(ids[:payments], "Payments", level_id: ids[:squad], parent_id: ids[:checkout],
                                                        effective_on: "2026-01-01")

      people = {
        ada: FactoryBot.create(:person, tenant:, name: "Ada Quill", job_title: "Engineering Manager", hris_level_ordinal: 5),
        brook: FactoryBot.create(:person, tenant:, name: "Brook Tamsin", job_title: "Engineer", hris_level_ordinal: 3),
        cyril: FactoryBot.create(:person, tenant:, name: "Cyril Moss", job_title: "Product Designer"),
        dot: FactoryBot.create(:person, tenant:, name: "Dot Fennick", job_title: "Engineer", hris_level_ordinal: 4),
        ezra: FactoryBot.create(:person, tenant:, name: "Ezra Pell", job_title: "Analyst", hris_level_ordinal: 3),
        faye: FactoryBot.create(:person, tenant:, name: "Faye Lumen", status: "inactive")
      }
      people.each_value { |person| handler.record_person(person.id, **PROVENANCE, employment_status: "employed") }

      handler.set_membership(people[:ada].id, ids[:platform], allocation: 1, **PROVENANCE)
      handler.set_membership(people[:brook].id, ids[:platform], allocation: 0.5, **PROVENANCE)
      handler.set_membership(people[:brook].id, ids[:checkout], allocation: 0.5, role: "Tech lead", **PROVENANCE)
      handler.set_membership(people[:cyril].id, ids[:checkout], **PROVENANCE)
      handler.set_membership(people[:dot].id, ids[:payments], allocation: 1, **PROVENANCE)

      ids.merge(people)
    end
  end

  # The #448 reproduction: Squads may sit under a Team or a Squad, and the person owns Payments and Ledger, a
  # second Squad under Platform, but not Checkout, the Team Payments sits under.
  # @return [String] Ledger's id
  def own_two_squads(tenant, org, person)
    ledger = SecureRandom.uuid_v7
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    ActsAsTenant.with_tenant(tenant) do
      structure.set_kind_parents(org[:squad], parent_ids: [ org[:team], org[:squad] ], top: false, effective_on: Date.current)
      structure.create_unit(ledger, "Ledger", level_id: org[:squad], parent_id: org[:platform], effective_on: Date.current)
      [ org[:payments], ledger ].each { |unit| structure.add_unit_owner(unit, person.id, effective_on: Date.current) }
    end
    ledger
  end
end
