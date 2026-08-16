defmodule Zer0Stream.IdempotencyRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "idempotency_records" do
    field(:operation, :string)
    field(:request_id, :string)
    field(:resource_id, :integer)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation, :request_id, :resource_id])
    |> validate_required([:operation, :request_id, :resource_id])
    |> unique_constraint(:request_id, name: :idempotency_records_operation_request_id_index)
  end
end
