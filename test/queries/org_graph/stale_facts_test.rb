# frozen_string_literal: true

require "test_helper"

class OrgGraph::StaleFactsTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    ActsAsTenant.with_tenant(@tenant) do
      @handler.change_site(@org[:ada].id, site: "Harbour", country: "AU", **PROVENANCE)
    end
  end

  def stale(*people) = ActsAsTenant.with_tenant(@tenant) { OrgGraph::StaleFacts.new(person_ids: people.map { @org[it].id }) }

  should "find nothing stale inside the tenant's threshold" do
    travel 89.days

    assert_nil stale(:ada).membership(@org[:ada].id, @org[:platform])
    assert_empty stale(:ada).employment(@org[:ada].id, "site")
  end

  should "find a membership and both facts of a pair once they pass it" do
    travel 91.days
    facts = stale(:ada, :brook)

    assert_equal @org[:platform], facts.membership(@org[:ada].id, @org[:platform]).unit_id
    assert facts.membership(@org[:brook].id, @org[:checkout])
    assert_equal %w[country site], facts.employment(@org[:ada].id, "site").map(&:fact).sort
    assert_empty facts.employment(@org[:ada].id, "started")
  end

  should "clear a membership once it is confirmed" do
    travel 91.days
    ActsAsTenant.with_tenant(@tenant) do
      @handler.confirm_fact(@org[:ada].id, "membership", unit_id: @org[:platform], confirmed_by_id: @org[:ezra].id,
                                                         effective_on: Date.current)
    end

    assert_nil stale(:ada).membership(@org[:ada].id, @org[:platform])
  end

  should "look at no one when given no one" do
    travel 91.days

    assert_nil stale.membership(@org[:ada].id, @org[:platform])
  end

  should "know the facts behind every employment line the person drawer shows" do
    assert_equal OrgGraph::PersonProfile::EMPLOYMENT.keys.sort, OrgGraph::StaleFacts::EMPLOYMENT.keys.sort
  end
end
