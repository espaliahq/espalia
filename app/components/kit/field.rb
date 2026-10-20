# frozen_string_literal: true

# Class strings for form fields, so every field shares one fill, edge and
# focus. A module, not a component, because most fields come from Rails form
# builders (`f.text_field`, `select_tag`).
#
# Focus darkens and thickens the edge (an inset ring on top of the border, so
# nothing shifts); there is no offset ring around a field.
#
# @example A text field
#   f.text_field :name, class: Components::Kit::Field::INPUT
#
# @example A field that failed validation
#   f.text_field :name, class: [Components::Kit::Field::INPUT, Components::Kit::Field::INVALID],
#                       aria: { invalid: true }
module Components::Kit::Field
  INPUT = "block w-full rounded-md border border-field bg-field px-3 py-2 text-sm text-default " \
          "placeholder:text-muted " \
          "focus:border-strong focus:ring-1 focus:ring-inset focus:ring-focus focus:outline-hidden " \
          "disabled:cursor-not-allowed disabled:border-disabled disabled:bg-subtle disabled:text-disabled"

  TEXTAREA = INPUT

  # The forms plugin draws the chevron in the right padding, hence pr-10.
  SELECT = "block w-full rounded-md border border-field bg-field py-2 pr-10 pl-3 text-sm text-default " \
           "focus:border-strong focus:ring-1 focus:ring-inset focus:ring-focus focus:outline-hidden " \
           "disabled:cursor-not-allowed disabled:border-disabled disabled:bg-subtle disabled:text-disabled"

  # Compact, for the inline editors that swap a label for a field in place.
  INLINE = "block w-full rounded-md border border-field bg-field px-2 py-1 text-sm text-default " \
           "placeholder:text-muted " \
           "focus:border-strong focus:ring-1 focus:ring-inset focus:ring-focus focus:outline-hidden " \
           "disabled:cursor-not-allowed disabled:border-disabled disabled:bg-subtle disabled:text-disabled"

  # The forms plugin hides the outline on these, so keyboard focus is a ring; the checked edge stays for dark cards.
  # Its white SVG tick vanishes on a pale brand, and an SVG can't read a variable, so two gradient strokes draw the tick in the contrast helper's ink.
  CHECKBOX = "size-4 rounded-sm border border-strong bg-field checked:border-strong checked:bg-brand-strong " \
             "checked:bg-[linear-gradient(45deg,transparent_calc(50%-1px),var(--gos-brand-content-inverse)_calc(50%-1px)_calc(50%+1px),transparent_calc(50%+1px)),linear-gradient(135deg,transparent_calc(50%-1px),var(--gos-brand-content-inverse)_calc(50%-1px)_calc(50%+1px),transparent_calc(50%+1px))] " \
             "checked:bg-size-[4px_4px,7.5px_7.5px] checked:bg-position-[2px_6.5px,4.5px_3.5px] checked:bg-no-repeat " \
             "focus:ring-0 focus:ring-offset-0 focus-visible:ring-2 focus-visible:ring-focus " \
             "disabled:cursor-not-allowed disabled:opacity-50"

  RADIO = "size-4 rounded-full border border-strong bg-field checked:border-strong checked:bg-brand-strong " \
          "focus:ring-0 focus:ring-offset-0 focus-visible:ring-2 focus-visible:ring-focus " \
          "disabled:cursor-not-allowed disabled:opacity-50"

  # Appended to a field that failed validation; pair it with aria-invalid. Important, so it beats the base edge.
  INVALID = "border-danger-strong!"
end
