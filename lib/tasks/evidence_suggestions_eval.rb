# frozen_string_literal: true

# Scores placement suggestions against hand-placed fixtures
# (test/fixtures/files/evidence_suggestions/): thirty invented pieces of
# feedback and the cells a manager would place them on. Run it on every
# prompt change, before widening suggestions to more tenants:
#
#   bin/rails "evidence:suggestions:eval[acme]"                       # the model tenant "acme" has configured
#   MODEL=claude-haiku-5-5 bin/rails "evidence:suggestions:eval[acme]" # another model on the same endpoint
#   SUGGESTION_MODEL=baseline bin/rails evidence:suggestions:eval      # word-overlap baseline, no API call
#
# The tenant's own adapter, effort and name hiding run, so a gateway model is
# scored the way it will answer in production. The tenant is only read (its
# model config and key); the fixture people are written to a throwaway one.
#
# The fixture framework and items are written into a throwaway tenant inside
# a transaction that is always rolled back, so the real Evidence::PlacementPrompt
# builds every request and nothing is left behind. Not run in CI.
class EvidenceSuggestionsEval
  FIXTURES = Rails.root.join("test/fixtures/files/evidence_suggestions")

  # A model that needs no API: the open cell at the person's level whose
  # capability and expectation share the most words with the feedback, read
  # as "demonstrated". The number the real model has to beat.
  class BaselineModel
    STOPWORDS = %w[the a an and or to of in on for with they their them was were is are it that this as at by].freeze

    def model = "baseline"
    def provider = "baseline"

    def suggest(prompt)
      words = tokens(prompt.item.content)
      best = prompt.open_cells.values
        .select { |cell| cell[:level_ordinal] == prompt.home_ordinal }
        .max_by { |cell| (tokens("#{cell[:capability_name]} #{cell[:expectation]}") & words).size }
      return [] if best.nil? || (tokens("#{best[:capability_name]} #{best[:expectation]}") & words).empty?

      [ Evidence::SuggestionModel::Proposal.new(capability_stable_id: best[:capability_stable_id],
          level_ordinal: best[:level_ordinal], valence: "demonstrated", confidence: 0.5, rationale: "word overlap") ]
    end

    private

    def tokens(text) = text.to_s.downcase.scan(/[a-z]+/) - STOPWORDS
  end

  # The model a tenant has configured, as the eval scores it: the real
  # pipeline, adapter and pseudonymiser included.
  #
  # @param slug [String, nil] the tenant whose AI model to run
  # @param model [String, nil] a model id to use instead of the configured one
  # @return [Evidence::SuggestionModel]
  # @raise [ArgumentError] when there is no such tenant or it has no model and key
  def self.model_for(slug:, model: nil)
    raise ArgumentError, "Name a tenant: bin/rails \"evidence:suggestions:eval[<slug>]\" (or SUGGESTION_MODEL=baseline)" if slug.blank?

    tenant = Tenant.find_by(slug: slug) or raise ArgumentError, "No tenant with the slug #{slug.inspect}"
    unless Evidence::SuggestionModel.configured?(tenant)
      raise ArgumentError, "#{tenant.name} has no AI model configured (Integrations > AI model); try SUGGESTION_MODEL=baseline"
    end

    Evidence::SuggestionModel.new(tenant: tenant, adapter: Ai::ModelClient.for(tenant, model: model))
  end

  Result = Struct.new(:id, :expected, :proposals, keyword_init: true)

  # @param model [#suggest, #model]
  def initialize(model:)
    @model = model
  end

  # @return [Hash] the report: counts and match rates, plus one row per item
  def run
    results = []
    ActiveRecord::Base.transaction(requires_new: true) do
      tenant = Tenant.create!(name: "Suggestion eval", slug: "suggestion-eval-#{SecureRandom.hex(4)}")
      ActsAsTenant.with_tenant(tenant) do
        build_framework(tenant)
        items.each { |fixture| results << evaluate(tenant, fixture) }
      end
      raise ActiveRecord::Rollback
    end
    report(results)
  end

  private

  def framework_fixture = @framework_fixture ||= JSON.parse(File.read(FIXTURES.join("framework.json")))
  def items = JSON.parse(File.read(FIXTURES.join("items.json")))["items"]

  def build_framework(tenant)
    @framework_id = SecureRandom.uuid_v7
    FrameworkState::Framework.create!(tenant: tenant, framework_id: @framework_id, name: "Eval framework")
    family = FrameworkState::RoleFamily.create!(tenant: tenant, framework_id: @framework_id, role_family_id: SecureRandom.uuid_v7, name: "Engineering")
    role_fixture = framework_fixture["role"]
    @role = FrameworkState::Role.create!(tenant: tenant, role_family_id: family.role_family_id, role_id: SecureRandom.uuid_v7,
                                         name: role_fixture["name"], code: role_fixture["code"], track: "ic")
    @levels = framework_fixture["levels"].to_h do |level|
      [ level["ordinal"], FrameworkState::Level.create!(tenant: tenant, role_id: @role.role_id, level_id: SecureRandom.uuid_v7,
          ordinal: level["ordinal"], title: level["title"], code: "#{role_fixture['code']}#{level['ordinal']}", is_entry: false) ]
    end
    categories = {}
    @stable_ids = framework_fixture["capabilities"].to_h do |cap|
      category = categories[cap["category"]] ||= FrameworkState::CapabilityCategory.create!(
        tenant: tenant, framework_id: @framework_id, category_id: SecureRandom.uuid_v7, name: cap["category"], ordinal: categories.size + 1
      )
      capability = FrameworkState::Capability.create!(tenant: tenant, category_id: category.category_id, capability_id: SecureRandom.uuid_v7,
                                                      stable_id: SecureRandom.uuid_v7, name: cap["name"], description: cap["description"], status: "active")
      FrameworkState::CapabilityRoleBinding.create!(tenant: tenant, binding_id: SecureRandom.uuid_v7,
                                                   capability_id: capability.capability_id, role_id: @role.role_id, weight: 1.0)
      cap["expectations"].each do |ordinal, text|
        expectation = FrameworkState::BehaviouralExpectation.create!(tenant: tenant, expectation_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
                                                                     capability_id: capability.capability_id, level_ordinal: ordinal.to_i, description: text)
        Array(cap.dig("illustrations", ordinal)).each_with_index do |example, index|
          FrameworkState::RoleIllustration.create!(tenant: tenant, illustration_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
                                                   expectation_id: expectation.expectation_id, role_id: @role.role_id, ordinal: index + 1, description: example)
        end
      end
      [ cap["key"], capability.stable_id ]
    end
    @author = Person.create!(tenant: tenant, name: "Eval Author", email: "eval-author-#{SecureRandom.hex(4)}@example.invalid")
  end

  def evaluate(tenant, fixture)
    person = Person.create!(tenant: tenant, name: "Eval #{fixture['id']}", email: "#{fixture['id']}-#{SecureRandom.hex(4)}@example.invalid")
    PersonFrameworkAssignment.create!(tenant: tenant, person_id: person.id, framework_id: @framework_id,
                                      role_id: @role.role_id, level_id: @levels.fetch(fixture["home_level"]).level_id)
    item = EvidenceItem.create!(
      id: SecureRandom.uuid_v7, tenant: tenant, person_id: person.id, framework_id: @framework_id, author: @author,
      source: fixture["direction"] == "manager_to_report" ? "manager" : "peer", feedback_direction: fixture["direction"],
      evidence_type: fixture["evidence_type"], content: fixture["content"], link_status: "active", recorded_at: Time.current
    )
    prompt = Evidence::PlacementPrompt.new(item)
    proposals = prompt.available? ? @model.suggest(prompt).select { |p| prompt.open_cell?(p.capability_stable_id, p.level_ordinal) } : []
    expected = fixture["expected"].map { |cell| [ @stable_ids.fetch(cell["capability"]), cell["level"], cell["valence"] ] }
    Result.new(id: fixture["id"], expected: expected, proposals: proposals)
  end

  def report(results)
    placeable = results.reject { |r| r.expected.empty? }
    uncovered = results - placeable
    top_hits = placeable.count { |r| (top = r.proposals.first) && expected_cells(r).include?(cell(top)) }
    any_hits = placeable.count { |r| r.proposals.any? { |p| expected_cells(r).include?(cell(p)) } }
    matched = placeable.flat_map { |r| r.proposals.filter_map { |p| [ p, r.expected.find { |e| e.first(2) == cell(p) } ] if expected_cells(r).include?(cell(p)) } }
    proposed = results.sum { |r| r.proposals.size }
    correct = placeable.sum { |r| r.proposals.count { |p| expected_cells(r).include?(cell(p)) } }

    {
      prompt_version: Evidence::PlacementPrompt::VERSION, provider: @model.provider, model: @model.model, items: results.size,
      placeable: placeable.size, uncovered: uncovered.size,
      cell_match_top: rate(top_hits, placeable.size), cell_match_any: rate(any_hits, placeable.size),
      valence_match: rate(matched.count { |p, e| p.valence == e.last }, matched.size),
      precision: rate(correct, proposed),
      uncovered_left_empty: rate(uncovered.count { |r| r.proposals.empty? }, uncovered.size),
      rows: results.map { |r| { id: r.id, uncovered: r.expected.empty?, proposed: r.proposals.size, hit: hit?(r) } }
    }
  end

  # A hit is a suggestion on a hand-placed cell, or no suggestion for
  # feedback the framework doesn't cover.
  def hit?(result)
    return result.proposals.empty? if result.expected.empty?

    result.proposals.any? { |p| expected_cells(result).include?(cell(p)) }
  end

  def cell(proposal) = [ proposal.capability_stable_id, proposal.level_ordinal ]
  def expected_cells(result) = result.expected.map { |e| e.first(2) }
  def rate(numerator, denominator) = denominator.zero? ? nil : (numerator.to_f / denominator).round(3)
end
