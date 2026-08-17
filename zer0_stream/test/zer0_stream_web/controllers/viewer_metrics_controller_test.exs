defmodule Zer0StreamWeb.ViewerMetricsControllerTest do
  use Zer0StreamWeb.ConnCase

  alias Zer0Stream.{Ingest, Streams}

  test "persists worker viewer samples and returns a durable historical series", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "viewer-metrics-creator"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Viewer Metrics"})
    {:ok, %{token: token}} = Streams.rotate_creator_stream_key(creator)
    {:ok, session} = Ingest.authorize_rtmp(token, "viewer-metrics-connection")

    sample_path = "/api/ingest/sessions/#{session.id}/viewer-samples"
    sample_params = %{viewer_count: 3}

    sample_conn =
      conn
      |> service_conn(:worker, :post, sample_path, sample_params)
      |> post(sample_path, sample_params)

    assert %{
             "viewer_sample" => %{
               "stream_id" => stream_id,
               "stream_session_id" => session_id,
               "viewer_count" => 3,
               "sampled_at" => sampled_at
             }
           } = json_response(sample_conn, 201)

    assert stream_id == stream.id
    assert session_id == session.id
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(sampled_at)

    metrics_path = "/api/streams/#{stream.id}/viewer-metrics"

    metrics_conn =
      build_conn()
      |> service_conn(:get, metrics_path, %{})
      |> get(metrics_path)

    assert %{
             "stream_id" => ^stream_id,
             "average_viewer_count" => 3.0,
             "samples" => [
               %{
                 "stream_session_id" => ^session_id,
                 "viewer_count" => 3,
                 "sampled_at" => ^sampled_at
               }
             ]
           } = json_response(metrics_conn, 200)
  end
end
