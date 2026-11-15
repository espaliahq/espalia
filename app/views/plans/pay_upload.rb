# frozen_string_literal: true

# A file of actual pay for one scenario, previewed before anything is held
# ([#323](https://github.com/espaliahq/espalia/issues/323)). The preview lands
# in a frame below the form, so the chosen file stays in its input and the
# confirm sends it again with the preview's signature.
class Views::Plans::PayUpload < Views::Base
  FORM_ID = "pay-upload-form"
  FRAME_ID = "pay-upload-preview"

  BASES = {
    "full_time" => [ "Full-time pay", "A full-time figure, which the person's FTE scales. Hourly rates take this one." ],
    "actual" => [ "Actual pay", "What the person is paid as it is, already pro-rated, which FTE leaves alone." ]
  }.freeze

  FILE_PROBLEMS = {
    "empty" => "The file has no rows of pay.",
    "too_large" => "The file is over 1 MB.",
    "bad_encoding" => "The file isn't UTF-8 text. Save it again as CSV UTF-8.",
    "missing_column" => "The file needs the columns person, amount, currency and period.",
    "too_many_rows" => "The file has more than 5,000 rows."
  }.freeze

  ROW_PROBLEMS = {
    "no_match" => "names no one in the organisation",
    "ambiguous_match" => "names more than one person",
    "not_on_map" => "names someone who isn't on this scenario's map",
    "duplicate_person" => "repeats someone from an earlier line",
    "bad_amount" => "has an amount that isn't a number above 0",
    "bad_currency" => "has a currency that isn't a three-letter ISO 4217 code",
    "bad_period" => "has a period other than year, month or hour",
    "hourly_actual" => "gives an hourly rate as actual pay, and a rate needs full-time pay"
  }.freeze

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param scenario_id [String] the scenario chosen
  # @param basis [String, nil] the basis chosen, nil until someone picks one
  # @param preview [Hash, nil] from {Operations::TeamPlanning::UploadActualPay}, without a signature sent
  # @param error [String, nil] why the last post was refused
  def initialize(plan:, scenarios:, scenario_id:, basis: nil, preview: nil, error: nil)
    @plan = plan
    @scenarios = scenarios
    @scenario_id = scenario_id
    @basis = basis
    @preview = preview
    @error = error
  end

  def view_template
    section(aria: { labelledby: "pay-upload-heading" }, class: "max-w-3xl space-y-6", data: { pay_upload: true }) do
      div do
        h3(id: "pay-upload-heading", class: "text-base font-semibold text-default") { "Upload actual pay" }
        p(class: "mt-1 text-sm text-muted") do
          "Price seats from what people are paid, rather than band midpoints. Only members with the see-pay right see it. " \
            "The file is read to check it and then dropped: nothing is held until you confirm."
        end
      end
      render(Components::Kit::Alert.new(tone: :danger, role: "alert")) { @error } if @error
      upload_form
      turbo_frame_tag(FRAME_ID) { preview if @preview }
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def upload_form
    form(id: FORM_ID, action: pay_upload_plan_path(plan_id), method: "post", enctype: "multipart/form-data",
         class: "space-y-5", data: { turbo_frame: FRAME_ID }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      scenario_field
      file_field
      basis_field
      render Components::Kit::Button.new(type: :submit, variant: :outline, name: "intent", value: "preview") { "Check the file" }
    end
  end

  def scenario_field
    div do
      label(for: "pay-upload-scenario", class: "block text-sm font-medium text-default") { "Scenario" }
      select(id: "pay-upload-scenario", name: "scenario_id", class: "mt-1 #{Components::Kit::Field::SELECT} sm:max-w-sm") do
        @scenarios.each do |scenario|
          id = scenario[:scenario_id]
          option(value: id, selected: id == @scenario_id) { id == plan_id ? "Today" : scenario[:name] }
        end
      end
    end
  end

  def file_field
    div do
      label(for: "pay-upload-file", class: "block text-sm font-medium text-default") { "CSV file" }
      p(id: "pay-upload-file-hint", class: "mt-1 text-sm text-muted") do
        "Columns person, amount, currency and period, in any order. A person is their Espalia id, HRIS employee id or " \
          "work email. Period is year, month or hour. Up to 5,000 rows and 1 MB."
      end
      input(id: "pay-upload-file", type: "file", name: "file", accept: ".csv,text/csv", required: true,
            aria: { describedby: "pay-upload-file-hint" },
            class: "mt-2 block w-full text-sm text-default file:mr-3 file:rounded-md file:border file:border-field " \
                   "file:bg-field file:px-3 file:py-2 file:text-sm file:text-default")
    end
  end

  def basis_field
    fieldset do
      legend(class: "text-sm font-medium text-default") { "What the amounts are" }
      p(class: "mt-1 text-sm text-muted") { "This applies to every row." }
      div(class: "mt-2 space-y-2") do
        BASES.each do |value, (title, detail)|
          label(class: "flex items-start gap-2 text-sm text-default") do
            input(type: "radio", name: "basis", value:, checked: @basis == value, required: true,
                  class: "mt-0.5 #{Components::Kit::Field::RADIO}")
            span do
              span(class: "font-medium") { title }
              span(class: "block text-muted") { detail }
            end
          end
        end
      end
    end
  end

  def preview
    div(class: "space-y-4", data: { pay_upload_preview: @preview[:problem] || (@preview[:failures].any? ? "failures" : "ok") }) do
      if @preview[:problem]
        render(Components::Kit::Alert.new(tone: :danger, role: "alert")) { file_problem }
      elsif @preview[:failures].any?
        failures
      else
        ready
      end
    end
  end

  def file_problem
    return "The file stops reading as CSV at line #{@preview[:line]}." if @preview[:problem] == "bad_csv"

    FILE_PROBLEMS.fetch(@preview[:problem])
  end

  def failures
    count = @preview[:failures].size
    render Components::Kit::Alert.new(tone: :danger, role: "alert",
                                      title: "#{count} #{count == 1 ? 'line needs' : 'lines need'} fixing, so nothing will be held") do
      ul(class: "mt-1 list-disc space-y-1 pl-5") do
        @preview[:failures].each do |failure|
          li(data: { pay_upload_line: failure[:line] }) do
            "Line #{failure[:line]} #{failure[:codes].map { ROW_PROBLEMS.fetch(it) }.to_sentence}."
          end
        end
      end
    end
  end

  def ready
    p(class: "text-sm text-default") do
      "Every amount reads as #{BASES.fetch(@preview[:basis]).first.downcase}, in #{scenario_name}."
    end
    render Components::Kit::DescriptionList.new(items: [
      { term: "Rows read", detail: @preview[:rows_read].to_s },
      { term: "People matched", detail: @preview[:matched_ids].size.to_s },
      { term: "Seats moving from band midpoints to actual pay", detail: @preview[:newly_priced_ids].size.to_s },
      { term: "Seats whose actual pay changes", detail: @preview[:replaced_ids].size.to_s },
      { term: "Already held as the file has it", detail: @preview[:unchanged_ids].size.to_s },
      { term: "People on the map the file leaves out", detail: @preview[:missing_ids].size.to_s }
    ], columns: 2)
    people("People matched", @preview[:matched_ids])
    people("People on the map the file leaves out", @preview[:missing_ids]) if @preview[:missing_ids].any?
    confirm
  end

  def people(title, ids)
    details(class: "text-sm text-default") do
      summary(class: "cursor-pointer font-medium") { "#{title} (#{ids.size})" }
      ul(class: "mt-2 columns-1 gap-6 sm:columns-2") do
        ids.each { |id| li(class: "break-words") { @preview[:names].fetch(id, Person::FORMER_MEMBER) } }
      end
    end
  end

  def confirm
    count = @preview[:matched_ids].size
    div(class: "flex flex-wrap items-center gap-2") do
      input(type: "hidden", name: "signature", value: @preview[:signature], form: FORM_ID)
      render Components::Kit::Button.new(type: :submit, tone: :brand, name: "intent", value: "confirm", form: FORM_ID,
                                         data: { turbo_frame: "_top" }) do
        "Hold pay for #{count} #{count == 1 ? 'person' : 'people'}"
      end
      render Components::Kit::Button.new(variant: :ghost, href: map_plan_path(plan_id, scenario: scenario_param), data: { turbo_frame: "_top" }) { "Cancel" }
    end
  end

  def scenario_name
    return "Today" if @scenario_id == plan_id

    @scenarios.find { it[:scenario_id] == @scenario_id }&.dig(:name) || "this scenario"
  end

  def scenario_param = (@scenario_id unless @scenario_id == plan_id)
end
