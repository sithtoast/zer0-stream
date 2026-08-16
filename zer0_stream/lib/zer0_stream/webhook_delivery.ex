defmodule Zer0Stream.WebhookDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  schema "webhook_deliveries" do
    field(:event_id, :string)
    field(:event_type, :string)
    field(:payload, :map)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:delivered_at, :utc_datetime)
    field(:last_error, :string)
    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :event_id,
      :event_type,
      :payload,
      :status,
      :attempts,
      :next_attempt_at,
      :delivered_at,
      :last_error
    ])
    |> validate_required([:event_id, :event_type, :payload, :status, :attempts, :next_attempt_at])
    |> validate_inclusion(:status, ["pending", "delivered", "failed"])
    |> unique_constraint(:event_id)
  end
end
