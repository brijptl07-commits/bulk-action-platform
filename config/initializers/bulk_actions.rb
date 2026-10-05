Rails.application.config.to_prepare do
  registry = BulkActions::EntityRegistry

  registry.register(
    :contact,
    model: "Contact",
    fields: { name: :string, email: :string, age: :integer, status: Contact::STATUSES },
    filterable_fields: %i[status age email],
    dedupe_field: :email
  )

  registry.register(
    :company,
    model: "Company",
    label: "Companies",
    fields: { name: :string, domain: :string, industry: Company::INDUSTRIES, employee_count: :integer,
              status: Company::STATUSES },
    filterable_fields: %i[status industry domain],
    dedupe_field: :domain
  )

  registry.register(
    :lead,
    model: "Lead",
    fields: { name: :string, email: :string, company_name: :string, source: Lead::SOURCES, score: :integer,
              status: Lead::STATUSES },
    filterable_fields: %i[status source email],
    dedupe_field: :email
  )

  registry.register(
    :opportunity,
    model: "Opportunity",
    label: "Opportunities",
    fields: { name: :string, amount: :decimal, stage: Opportunity::STAGES, probability: :integer, close_date: :date },
    filterable_fields: %i[stage company_id]
  )

  registry.register(
    :task,
    model: "Task",
    fields: { title: :string, description: :text, status: Task::STATUSES, priority: Task::PRIORITIES,
              due_date: :date, assignee: :string },
    filterable_fields: %i[status priority assignee]
  )

  BulkActions::ActionRegistry.register(:bulk_update, "BulkActions::Handlers::BulkUpdate")
end
