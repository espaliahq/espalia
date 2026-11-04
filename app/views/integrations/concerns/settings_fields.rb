# frozen_string_literal: true

# The form vocabulary every integration settings page shares: labelled fields
# with hints, the write-only secret field, the toggle, and the failed-save
# summary. One definition so the three pages cannot drift — above all the
# secret contract: the input's value is always empty, a stored secret shows
# only as a "••••••••" placeholder and a "Stored" label, and a blank submit
# keeps the stored value.
#
# An including view defines `field_prefix`, the param namespace its form posts
# under ("ai_model", "hris_connection", …).
module Views::Integrations::Concerns::SettingsFields
  INPUT_CLASSES = "#{Components::Kit::Field::INPUT} min-h-11 mt-1"
  SELECT_CLASSES = "#{Components::Kit::Field::SELECT} min-h-11 mt-1"
  LABEL_CLASSES = "block text-sm font-medium text-default"
  HINT_CLASSES = "mt-1 text-xs text-muted [overflow-wrap:anywhere]"

  # What a stored secret shows instead of its value. Placeholder only — it is
  # never the input's value, so nothing can submit or copy it.
  SECRET_PLACEHOLDER = "••••••••"

  private

  def field_id(name) = "#{field_prefix}_#{name}"
  def field_name(name) = "#{field_prefix}[#{name}]"

  def error_summary(title:)
    return if @errors.empty?

    render Components::Kit::Alert.new(tone: :danger, title: title, class: "mb-6") do
      ul(class: "mt-1 list-disc pl-5") { @errors.each { |message| li { message } } }
    end
  end

  def text_field(name, label_text, value:, hint:, type: "text", placeholder: nil, data: nil)
    div do
      label(for: field_id(name), class: LABEL_CLASSES) { label_text }
      input(type: type, id: field_id(name), name: field_name(name), value: value.to_s, placeholder: placeholder,
            autocomplete: "off", class: INPUT_CLASSES, data: data,
            aria: { describedby: "#{field_id(name)}-hint" })
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  def select_field(name, label_text, hint: nil, data: nil, &options)
    div do
      label(for: field_id(name), class: LABEL_CLASSES) { label_text }
      select(id: field_id(name), name: field_name(name), class: SELECT_CLASSES, autocomplete: "off", data: data,
             aria: (hint ? { describedby: "#{field_id(name)}-hint" } : {}), &options)
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint } if hint
    end
  end

  # @return [String] the one spelling of a secret's presence
  def stored_label(stored) = stored ? "Stored" : "Not set"

  # The "Stored" label stays beside the placeholder because a placeholder is
  # not reliably announced by screen readers.
  def secret_field(name, label_text, stored:, hint:, empty_placeholder:)
    div do
      label(for: field_id(name), class: LABEL_CLASSES) do
        plain label_text
        span(class: "ml-2 text-xs font-normal text-muted") { stored_label(stored) }
      end
      input(type: "password", id: field_id(name), name: field_name(name), value: "", autocomplete: "new-password",
            placeholder: stored ? SECRET_PLACEHOLDER : empty_placeholder,
            class: INPUT_CLASSES, aria: { describedby: "#{field_id(name)}-hint" })
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) do
        plain(stored ? "#{hint} Leave blank to keep the stored value." : hint)
      end
    end
  end

  def switch_field(name, label_text, checked, hint:)
    div do
      input(type: "hidden", name: field_name(name), value: "0")
      label(class: "inline-flex items-center gap-3 min-h-11 text-sm font-medium text-default cursor-pointer") do
        input(type: "checkbox", id: field_id(name), name: field_name(name), value: "1", checked: checked,
              class: Components::Kit::Field::CHECKBOX, aria: { describedby: "#{field_id(name)}-hint" })
        plain label_text
      end
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end
end
