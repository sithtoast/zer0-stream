defmodule Zer0Stream.Viewers do
  import Ecto.Query, only: [from: 2]

  alias Zer0Stream.Repo
  alias Zer0Stream.Streams.StreamSession
  alias Zer0Stream.Viewers.ViewerSample

  def record_sample(session_id, viewer_count)
      when is_integer(viewer_count) and viewer_count >= 0 do
    case Repo.get_by(StreamSession, id: session_id, status: "live") do
      nil ->
        {:error, :not_found}

      session ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        session
        |> Ecto.Changeset.change(last_activity_at: now)
        |> Repo.update!()

        %ViewerSample{}
        |> ViewerSample.changeset(%{
          stream_id: session.stream_id,
          stream_session_id: session.id,
          viewer_count: viewer_count,
          sampled_at: now |> DateTime.truncate(:second)
        })
        |> Repo.insert()
    end
  end

  def record_sample(_session_id, _viewer_count), do: {:error, :invalid_viewer_count}

  def historical_series(stream_id, limit \\ 100) do
    samples =
      Repo.all(
        from(sample in ViewerSample,
          where: sample.stream_id == ^stream_id,
          order_by: [desc: sample.sampled_at],
          limit: ^normalize_limit(limit)
        )
      )
      |> Enum.reverse()

    average_viewer_count =
      case samples do
        [] -> 0.0
        _ -> Enum.sum_by(samples, & &1.viewer_count) / length(samples)
      end

    %{samples: samples, average_viewer_count: average_viewer_count}
  end

  defp normalize_limit(limit) when is_integer(limit), do: min(max(limit, 1), 1_000)
  defp normalize_limit(_limit), do: 100
end
