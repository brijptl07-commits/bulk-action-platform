Rails.application.config.to_prepare do
  BulkActions::EntityRegistry.register(
    :contact,
    model: "Contact",
    updatable_fields: %i[name email age status],
    filterable_fields: %i[status age email],
    dedupe_field: :email
  )

  BulkActions::ActionRegistry.register(:bulk_update, "BulkActions::Handlers::BulkUpdate")
end
