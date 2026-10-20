# frozen_string_literal: true

# @label Description list
class Kit::DescriptionListPreview < Lookbook::Preview
  # @param columns select { choices: [1, 2, 3, 4] }
  # @param term text
  # @param detail text
  def playground(columns: 3, term: "Last synced", detail: "20 Oct 2026, 9:14 am")
    render Components::Kit::DescriptionList.new(
      items: [
        { term: term, detail: detail },
        { term: "Provider", detail: "HiBob" },
        { term: "Sync enabled", detail: "Yes" }
      ],
      columns: columns.to_i
    )
  end

  # @!group Layouts

  def hris_configuration
    render Components::Kit::DescriptionList.new(
      items: [
        { term: "Provider", detail: "HiBob" },
        { term: "Sync enabled", detail: "Yes" },
        { term: "Last synced", detail: "20 Oct 2026, 9:14 am" },
        { term: "Credentials", detail: "Yes" },
        { term: "Level column id", detail: "—" },
        { term: "Webhook secret", detail: "No" }
      ],
      columns: 3
    )
  end

  def two_columns
    render Components::Kit::DescriptionList.new(
      items: [
        { term: "Roles", detail: "11" },
        { term: "Capabilities", detail: "40" }
      ],
      columns: 2
    )
  end

  def one_column
    render Components::Kit::DescriptionList.new(
      items: [
        { term: "Framework", detail: "Engineering" },
        { term: "Version", detail: "v3" }
      ],
      columns: 1
    )
  end

  def four_columns
    render Components::Kit::DescriptionList.new(
      items: [
        { term: "Enrolled", detail: "42" },
        { term: "Self-assessed", detail: "37" },
        { term: "Manager rated", detail: "29" },
        { term: "Aligned", detail: "18" }
      ],
      columns: 4
    )
  end

  # @!endgroup

  # @!group States

  def long_detail
    render Components::Kit::DescriptionList.new(
      items: [
        { term: "Level column id", detail: "custom_field_engineering_career_level_2026" },
        { term: "Provider", detail: "BambooHR" },
        { term: "Last synced", detail: "Never" }
      ]
    )
  end

  def empty
    render Components::Kit::DescriptionList.new(items: [])
  end

  # @!endgroup
end
