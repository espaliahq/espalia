# frozen_string_literal: true

# Publish-review screen. The owner/editor validates the as-we-go migration
# mappings for every capability being retired in the draft — editing any that
# need it, all rows in one save — then requests the publish, which runs in the
# background ({Frameworks::PublishVersionJob}). Reached from the explorer's
# Publish button; the confirm submits to {Frameworks::PublicationsController#create}.
class Views::Frameworks::PublicationReviewView < Views::Base
  # Mapping types meaningful when retiring a capability; the subset needing a
  # surviving capability is wired to the mapping-form Stimulus controller.
  MAPPING_TYPES = [
    [ "evolved", "Evolved — into a survivor" ],
    [ "archived", "Archived — no replacement" ]
  ].freeze

  # @param framework [FrameworkState::Framework]
  # @param retiring [Array<Hash>] { capability:, mapping: } for each retiring capability
  # @param survivors [Array<Hash>] { name:, stable_id: } survivor candidates
  # @param publication [FrameworkPublication, nil] the latest publish request for this draft
  # @param changes [Hash{Symbol => Array<Hash>}] {Frameworks::DraftChangesQuery#call}
  def initialize(framework:, retiring:, survivors:, changes:, publication: nil, user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @changes = changes
    @retiring = retiring
    @survivors = survivors
    @publication = publication
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-2xl mx-auto px-4 py-8 space-y-6") do
        header
        publication_status
        changes_section
        retiring_section
        confirm_section
      end
    end
  end

  private

  def publishing? = @publication&.in_flight?

  def header
    div do
      a(href: edit_framework_path(@framework.framework_id),
        class: "text-sm text-muted hover:text-default") do
        plain "← Back to #{@framework.name}"
      end
      h1(class: "mt-2 text-2xl font-bold text-default") do
        plain "Publish v#{@framework.draft_version}"
      end
      p(class: "mt-1 text-sm text-muted") do
        plain "Review what this version changes, then publish. Publishing makes the draft " \
              "live and changes in-flight assessments — it cannot be undone."
      end
    end
  end

  # What the background publish is doing, or why the last attempt was refused.
  # Both are facts the requester would otherwise only learn from the bell. A
  # succeeded request means the draft is gone and this page is not reached.
  def publication_status
    return unless publishing? || @publication&.failed?

    if publishing?
      render Components::Kit::Alert.new do
        strong { "Publishing v#{@framework.draft_version}… " }
        plain "Requested "
        local_time_ago(@publication.created_at)
        plain " by #{@publication.requester&.name || 'a teammate'}. " \
              "Ratings, evidence and comments are being migrated; you'll be notified when it's live."
      end
    else
      render Components::Kit::Alert.new(tone: :danger) do
        strong { "The last publish attempt failed: " }
        plain @publication.error_message.to_s
        plain " Fix the mappings below and publish again."
      end
    end
  end

  CHANGE_HEADINGS = {
    capabilities_added: "Capabilities added",
    capabilities_archived: "Capabilities archived",
    categories_archived: "Categories archived",
    roles_removed: "Removed from a role",
    roles_added: "Added to a role",
    levels_added: "Levels added",
    levels_moved: "Levels moved",
    expectations_added: "Expectations added"
  }.freeze

  def changes_section
    groups = CHANGE_HEADINGS.keys.filter_map { |kind| [ kind, @changes[kind] ] if @changes[kind].present? }

    section(class: "space-y-3", aria_labelledby: "draft-changes-heading") do
      h2(id: "draft-changes-heading", class: "text-lg font-semibold text-default") do
        plain "What changes in v#{@framework.draft_version}"
      end
      p(class: "text-sm text-muted") do
        plain "These wait for you to publish. Renames, rewordings and examples are already live."
      end

      if groups.empty?
        p(class: "rounded-md bg-subtle px-4 py-3 text-sm text-muted") do
          plain "Nothing in this draft is waiting to be published."
        end
      else
        div(class: "rounded-md border border-default divide-y divide-default") do
          groups.each { |kind, items| change_group(kind, items) }
        end
      end
    end
  end

  def change_group(kind, items)
    div(class: "px-4 py-3", data: { draft_change: kind.to_s }) do
      h3(class: "text-sm font-semibold text-default") do
        plain "#{CHANGE_HEADINGS.fetch(kind)} (#{items.size})"
      end
      ul(class: "mt-2 space-y-1.5 text-sm text-muted") do
        items.each { |item| li { change_line(kind, item) } }
      end
      if kind == :roles_removed
        p(class: "mt-2 text-xs text-muted") do
          plain "Ratings already made on these are kept, but stop counting for that role."
        end
      end
    end
  end

  def change_line(kind, item)
    case kind
    when :capabilities_added
      strong(class: "font-medium") { item[:capability] }
      plain " in #{item[:category]}"
      plain " · #{item[:roles].to_sentence}" if item[:roles].any?
    when :capabilities_archived
      strong(class: "font-medium") { item[:capability] }
      reach(item[:open_cycle_people], "one of its roles")
    when :categories_archived
      strong(class: "font-medium") { item[:category] }
    when :roles_removed
      strong(class: "font-medium") { item[:capability] }
      plain " from #{item[:role]}"
      reach(item[:open_cycle_people], "that role")
    when :roles_added
      strong(class: "font-medium") { item[:capability] }
      plain " to #{item[:role]}"
    when :levels_added
      strong(class: "font-medium") { item[:level] }
      plain " #{item[:title]} · #{item[:role]}"
    when :levels_moved
      strong(class: "font-medium") { item[:level] }
      plain " #{item[:title]} · #{item[:role]} — from L#{item[:from]} to L#{item[:to]}"
    when :expectations_added
      strong(class: "font-medium") { item[:capability] }
      plain " · L#{item[:level_ordinal]}"
    end
  end

  # Counted by role, not by whether the capability has an expectation at each
  # person's level, so it says "hold", never "affects".
  def reach(people, held)
    return if people.zero?

    span(class: "text-muted") do
      plain " — #{people} #{people == 1 ? 'person' : 'people'} in the open cycle " \
            "#{people == 1 ? 'holds' : 'hold'} #{held}"
    end
  end

  def retiring_section
    return if @retiring.empty?

    div(class: "space-y-3") do
      render Components::Kit::SectionHeading.new(
        "Retiring #{@retiring.size} #{'capability'.pluralize(@retiring.size)}",
        subtitle: "Confirm or change how each one's existing ratings migrate, then save them together."
      )
      mappings_form
    end
  end

  # ONE form for every row: saving is a single action, so a choice made on one
  # row is never lost by saving another (the per-row forms this replaces
  # reloaded the page and dropped the others' unsaved selects).
  def mappings_form
    form(
      action: framework_migration_mappings_path(@framework.framework_id),
      method: "post",
      class: "space-y-3"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      @retiring.each_with_index { |entry, index| mapping_row(entry[:capability], entry[:mapping], index) }

      div(class: "flex items-center justify-end") do
        render Components::Kit::Button.new(type: :submit, data: { turbo_submits_with: "Saving…" }) do
          "Save #{'mapping'.pluralize(@retiring.size)}"
        end
      end
    end
  end

  def mapping_row(capability, mapping, index)
    prefix = "migration_mappings[#{index}]"
    render Components::Kit::Card.new(
      variant: :inset, density: :compact, edge: ("border-warning" unless mapping),
      data: { controller: "mapping-form",
              mapping_form_survivor_types_value: Operations::Frameworks::DefineMigrationMapping::SURVIVOR_TYPES.to_json }
    ) do |card|
      card.body { mapping_fields(capability, mapping, prefix) }
    end
  end

  def mapping_fields(capability, mapping, prefix)
    div(class: "flex items-center justify-between") do
      span(class: "font-medium text-default") { capability.name }
      unless mapping
        span(class: "text-xs font-semibold text-warning") { "Needs a mapping" }
      end
    end
    input(type: "hidden", name: "#{prefix}[from_stable_id]", value: capability.stable_id)
    input(type: "hidden", name: "#{prefix}[mapping_id]", value: mapping&.mapping_id)
    div(class: "mt-3 flex flex-wrap items-end gap-3") do
      type_select(mapping, prefix, capability)
      survivor_select(mapping, prefix, capability)
    end
  end

  def type_select(mapping, prefix, capability)
    id = "mapping-type-#{capability.stable_id}"
    div do
      label(for: id, class: "block text-xs font-medium text-muted mb-1") { "Mapping" }
      select(
        id: id, name: "#{prefix}[mapping_type]", class: Components::Kit::Field::SELECT,
        data: { mapping_form_target: "type", action: "change->mapping-form#typeChanged" }
      ) do
        # An undecided row submits blank and is left alone by the save — it must
        # not default to the first type and then be reported as incomplete.
        option(value: "", selected: mapping.nil?) { "— choose —" } if mapping.nil?
        MAPPING_TYPES.each do |value, text|
          option(value: value, selected: mapping&.mapping_type == value) { text }
        end
      end
    end
  end

  def survivor_select(mapping, prefix, capability)
    id = "mapping-survivor-#{capability.stable_id}"
    div(data: { mapping_form_target: "survivor" }) do
      label(for: id, class: "block text-xs font-medium text-muted mb-1") { "Survivor" }
      select(id: id, name: "#{prefix}[to_stable_id]", class: Components::Kit::Field::SELECT) do
        option(value: "") { "— select —" }
        @survivors.each do |s|
          option(value: s[:stable_id], selected: mapping&.to_stable_id == s[:stable_id]) { s[:name] }
        end
      end
    end
  end

  # Turbo disables the submitter for the life of the request and swaps in the
  # `data-turbo-submits-with` copy, so a second click during the round trip is
  # impossible; the disabled rendering covers a publish already in flight from
  # an earlier request or another tab.
  def confirm_section
    form(
      action: framework_publication_path(@framework.framework_id),
      method: "post",
      class: "border-t border-default pt-6 flex items-center gap-3"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      if publishing?
        render Components::Kit::Button.new(tone: :brand, disabled: true, aria: { disabled: "true" }) do
          "Publishing v#{@framework.draft_version}…"
        end
      else
        render Components::Kit::Button.new(
          tone: :brand, type: :submit, data: { turbo_submits_with: "Publishing v#{@framework.draft_version}…" }
        ) { "Confirm & publish v#{@framework.draft_version}" }
      end
      render Components::Kit::Button.new(variant: :ghost, href: edit_framework_path(@framework.framework_id)) { "Cancel" }
    end
  end
end
