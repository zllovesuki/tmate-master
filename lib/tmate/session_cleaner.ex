defmodule Tmate.SessionCleaner do
  require Logger

  alias Tmate.Repo
  alias Tmate.Session
  alias Tmate.Event
  import Ecto.Query

  def prune_sessions() do
    prune_sessions({1, "week"})
  end

  def prune_sessions({timeout_value, timeout_unit}) do
    Logger.info("Pruning dead sessions older than #{timeout_value} #{timeout_unit}")

    {n_pruned, sids} = from(s in Session,
              where: s.disconnected_at < ago(^timeout_value, ^timeout_unit),
              select: s.id)
    |> Repo.delete_all

    if n_pruned != 0 do
      Logger.info("Pruned #{n_pruned} dead sessions: #{sids}")
    end

    :ok
  end

  def check_for_disconnected_sessions() do
    Logger.info("Checking for disconnected sessions")
    from(s in Session, where: is_nil(s.disconnected_at),
                       select: {s.id, s.ws_url_fmt})
    |> Repo.all
    |> Enum.group_by(fn {_id, ws_url_fmt} -> ws_url_fmt end,
                     fn {id, _ws_url_fmt} -> id end)
    |> Enum.each(fn {ws_url_fmt, session_ids} ->
      base_url = Session.wsapi_base_url(ws_url_fmt)
      check_for_disconnected_sessions(base_url, session_ids)
    end)

    :ok
  end

  defp check_for_disconnected_sessions(base_url, session_ids) do
    # When a websocket serves goes down, it does not necessarily notify disconnections.
    # We'll emit these missings events here.

    # 1) we get the generations of the sessions
    sid_generations =
      from(e in Event, where: e.entity_id in ^session_ids,
                       group_by: e.entity_id,
                       select: {e.entity_id, max(e.generation)})
      |> Repo.all
      |> Map.new

    # 2) we get the stale entries
    case sid_generations
         |> Map.keys
         |> Tmate.WsApi.get_stale_sessions(base_url) do
      {:ok, stale_ids} ->
        stale_ids
        |> Enum.map(& {&1, sid_generations[&1]})
        |> Enum.each(fn {sid, generation} ->
  # 3) emit the events for the stale entries
          Logger.warn("Emitting disconnect event for stale session id=#{sid}")
          Event.emit!(:session_disconnect, sid, DateTime.utc_now, generation, %{})
        end)
      {:error, _} ->
        nil # error is already logged
    end
  end
end
