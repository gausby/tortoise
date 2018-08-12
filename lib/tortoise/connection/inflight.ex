defmodule Tortoise.Connection.Inflight do
  @moduledoc false

  alias Tortoise.{Package, Connection}
  alias Tortoise.Connection.Controller
  alias Tortoise.Connection.Inflight.Track

  use GenStateMachine

  @enforce_keys [:client_id]
  defstruct client_id: nil, pending: %{}, connection: nil

  alias __MODULE__, as: State

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    GenStateMachine.start_link(__MODULE__, opts, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def stop(client_id) do
    GenStateMachine.stop(via_name(client_id))
  end

  def track(client_id, {:incoming, %Package.Publish{qos: qos, dup: false} = publish})
      when qos in 1..2 do
    :ok = GenStateMachine.cast(via_name(client_id), {:incoming, publish})
  end

  def track(client_id, {:outgoing, package}) do
    caller = {_, ref} = {self(), make_ref()}

    case package do
      %Package.Publish{qos: qos} when qos in 1..2 ->
        :ok = GenStateMachine.cast(via_name(client_id), {:outgoing, caller, package})
        {:ok, ref}

      %Package.Subscribe{} ->
        :ok = GenStateMachine.cast(via_name(client_id), {:outgoing, caller, package})
        {:ok, ref}

      %Package.Unsubscribe{} ->
        :ok = GenStateMachine.cast(via_name(client_id), {:outgoing, caller, package})
        {:ok, ref}
    end
  end

  def track_sync(client_id, {:outgoing, _} = command, timeout \\ :infinity) do
    {:ok, ref} = track(client_id, command)

    receive do
      {{Tortoise, ^client_id}, ^ref, result} ->
        result
    after
      timeout -> {:error, :timeout}
    end
  end

  def update(client_id, {_, %{__struct__: _, identifier: _identifier}} = event) do
    :ok = GenStateMachine.cast(via_name(client_id), {:update, event})
  end

  # Server callbacks
  @impl true
  def init(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    initial_data = %State{client_id: client_id}

    next_actions = [
      {:next_event, :internal, :post_init}
    ]

    {:ok, :disconnected, initial_data, next_actions}
  end

  @impl true
  def handle_event(:internal, :post_init, :disconnected, data) do
    case Connection.connection(data.client_id, active: true) do
      {:ok, {_transport, _socket} = connection} ->
        {:next_state, :connected, %State{data | connection: connection}}

      {:error, :timeout} ->
        {:stop, :connection_timeout}

      {:error, :unknown_connection} ->
        {:stop, :unknown_connection}
    end
  end

  def handle_event(
        :info,
        {{Tortoise, client_id}, :connection, {transport, socket}},
        :disconnected,
        %State{client_id: client_id} = data
      ) do
    {:next_action, :connected, %State{data | connection: {transport, socket}}}
  end

  def handle_event(:cast, {:incoming, package}, :connected, data) do
    track = Track.create(:positive, package)
    updated_pending = Map.put_new(data.pending, track.identifier, track)

    case execute(track, %State{data | pending: updated_pending}) do
      {:ok, data} ->
        {:keep_state, data}
    end
  end

  def handle_event(:cast, {:outgoing, caller, package}, :connected, data) do
    {:ok, package} = assign_identifier(package, data.pending)
    track = Track.create({:negative, caller}, package)
    updated_pending = Map.put_new(data.pending, track.identifier, track)

    case execute(track, %State{data | pending: updated_pending}) do
      {:ok, data} ->
        {:keep_state, data}
    end
  end

  def handle_event(:cast, {:update, update}, :connected, data) do
    {:ok, next_action, data} = progress_track_state(update, data)

    case execute(next_action, data) do
      {:ok, data} ->
        {:keep_state, data}
    end
  end

  # helpers

  defp execute(
         %Track{pending: [[{:dispatch, package}, _] | _]},
         %State{connection: {transport, socket}} = state
       ) do
    case apply(transport, :send, [socket, Package.encode(package)]) do
      :ok ->
        {:ok, state}

        # {:error, :closed} ->
        #   nil
    end
  end

  defp execute(
         %Track{pending: [[{:respond, _caller}, _] | _]} = track,
         %State{} = state
       ) do
    :ok = Controller.handle_result(state.client_id, track)
    {:ok, state}
  end

  defp progress_track_state({_, package} = input, %State{} = state) do
    {next_action, updated_pending} =
      Map.get_and_update!(state.pending, package.identifier, fn track ->
        updated_track = Track.resolve(track, input)

        {updated_track, updated_track}
      end)

    {:ok, next_action, %State{state | pending: updated_pending}}
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
