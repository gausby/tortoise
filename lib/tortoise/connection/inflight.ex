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
    :ok = GenServer.cast(via_name(client_id), {:incoming, publish})
  end

  def track(client_id, {:outgoing, %Package.Publish{qos: qos} = publish})
      when qos in 1..2 do
    caller = {_, ref} = {self(), make_ref()}
    :ok = GenServer.cast(via_name(client_id), {:outgoing, caller, publish})
    {:ok, ref}
  end

  def track(client_id, {:outgoing, %Package.Subscribe{} = subscribe}) do
    caller = {_, ref} = {self(), make_ref()}
    :ok = GenServer.cast(via_name(client_id), {:outgoing, caller, subscribe})
    {:ok, ref}
  end

  def track(client_id, {:outgoing, %Package.Unsubscribe{} = unsubscribe}) do
    caller = {_, ref} = {self(), make_ref()}
    :ok = GenServer.cast(via_name(client_id), {:outgoing, caller, unsubscribe})
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

  def handle_cast({:incoming, package}, %{pending: pending} = state) do
    track = Track.create(:positive, package)
    updated_pending = Map.put_new(pending, track.identifier, track)

    case execute(track, %__MODULE__{state | pending: updated_pending}) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  def handle_cast({:outgoing, caller, package}, %{pending: pending} = state) do
    {:ok, package} = assign_identifier(package, pending)
    track = Track.create({:negative, caller}, package)
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

  # Assign a random identifier to the tracked package; this will make
  # sure we pick a random number that is not in use
  defp assign_identifier(%{identifier: nil} = package, pending) do
    case :crypto.strong_rand_bytes(2) do
      <<0, 0>> ->
        # an identifier cannot be zero
        assign_identifier(package, pending)

      <<identifier::integer-size(16)>> ->
        unless Map.has_key?(pending, identifier) do
          {:ok, %{package | identifier: identifier}}
        else
          assign_identifier(package, pending)
        end
    end
  end

  # ...as such we should let the in-flight process assign identifiers,
  # but the possibility to pass one in has been kept so we can make
  # deterministic unit tests
  defp assign_identifier(%{identifier: identifier} = package, pending)
       when identifier in 0x0001..0xFFFF do
    unless Map.has_key?(pending, identifier) do
      {:ok, package}
    else
      {:error, {:identifier_already_in_use, identifier}}
    end
  end
end
