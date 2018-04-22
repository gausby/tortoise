defmodule Tortoise.Connection.Inflight do
  @moduledoc """
  A process keeping track of the messages in flight
  """

  alias Tortoise.Package
  alias Tortoise.Connection.Transmitter
  alias Tortoise.Connection.Inflight.Track

  use GenServer

  defstruct pending: %{}, client_id: nil

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    initial_state = %__MODULE__{client_id: client_id}
    GenServer.start_link(__MODULE__, initial_state, name: via_name(client_id))
  end

  def via_name(pid) when is_pid(pid), do: pid

  def via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def stop(client_id) do
    GenServer.stop(via_name(client_id))
  end

  def track(client_id, {:incoming, %Package.Publish{qos: qos, dup: false} = publish})
      when qos in 1..2 do
    track = Track.create(:positive, publish)
    :ok = GenServer.cast(via_name(client_id), {:track, track})
  end

  def track(client_id, {:outgoing, %Package.Publish{qos: qos} = publish})
      when qos in 1..2 do
    ref = make_ref()
    track = Track.create({:negative, {self(), ref}}, publish)
    :ok = GenServer.cast(via_name(client_id), {:track, track})
    {:ok, ref}
  end

  def track(client_id, {:outgoing, %Package.Subscribe{} = subscribe}) do
    ref = make_ref()
    track = Track.create({:negative, {self(), ref}}, subscribe)
    :ok = GenServer.cast(via_name(client_id), {:track, track})
    {:ok, ref}
  end

  def track(client_id, {:outgoing, %Package.Unsubscribe{} = unsubscribe}) do
    ref = make_ref()
    track = Track.create({:negative, {self(), ref}}, unsubscribe)
    :ok = GenServer.cast(via_name(client_id), {:track, track})
    {:ok, ref}
  end

  def track_sync(client_id, {:outgoing, _} = command, timeout \\ :infinity) do
    {:ok, ref} = track(client_id, command)

    receive do
      {Tortoise, {{^client_id, ^ref}, result}} ->
        result
    after
      timeout -> {:error, :timeout}
    end
  end

  def update(client_id, {_, %{__struct__: _, identifier: _identifier}} = event) do
    :ok = GenServer.cast(via_name(client_id), {:update, event})
  end

  # Server callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_cast({:track, track}, %{pending: pending} = state) do
    updated_pending = Map.put_new(pending, track.identifier, track)

    case execute(track, %__MODULE__{state | pending: updated_pending}) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  def handle_cast({:update, update}, state) do
    {:ok, next_action, state} = progress_track_state(update, state)

    case execute(next_action, state) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  # helpers

  defp execute(%Track{pending: [{:dispatch, package} | _]}, state) do
    :ok = Transmitter.cast(state.client_id, package)
    update = {:dispatched, package}
    {:ok, next_action, state} = progress_track_state(update, state)
    execute(next_action, state)
  end

  defp execute(%Track{pending: [{:expect, _} | _]}, state) do
    # await
    {:ok, state}
  end

  defp execute(%Track{pending: []} = track, state) do
    :ok = respond_caller(track, state)
    pending = Map.delete(state.pending, track.identifier)
    {:ok, %__MODULE__{state | pending: pending}}
  end

  defp progress_track_state({_, package} = input, %__MODULE__{} = state) do
    # todo, handle possible error
    {next_action, updated_pending} =
      Map.get_and_update!(state.pending, package.identifier, fn track ->
        updated_track = Track.update(track, input)
        {updated_track, updated_track}
      end)

    {:ok, next_action, %__MODULE__{state | pending: updated_pending}}
  end

  defp respond_caller(%Track{caller: nil}, _), do: :ok

  defp respond_caller(%Track{caller: {pid, ref}, result: result}, state)
       when is_pid(pid) do
    send(pid, {Tortoise, {{state.client_id, ref}, result}})
    :ok
  end
end
