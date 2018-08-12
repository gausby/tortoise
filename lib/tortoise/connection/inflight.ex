defmodule Tortoise.Connection.Inflight do
  @moduledoc false

  alias Tortoise.{Package, Connection}
  alias Tortoise.Connection.Controller
  alias Tortoise.Connection.Inflight.Track

  use GenStateMachine

  @enforce_keys [:client_id]
  defstruct client_id: nil, pending: %{}

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
        {:ok, _} = Tortoise.Events.register(data.client_id, :status)
        {:next_state, {:connected, connection}, data}

      {:error, :timeout} ->
        {:stop, :connection_timeout}

      {:error, :unknown_connection} ->
        {:stop, :unknown_connection}
    end
  end

  # When we receive a new connection we will use that for our future
  # transmissions.
  def handle_event(
        :info,
        {{Tortoise, client_id}, :connection, connection},
        _current_state,
        %State{client_id: client_id} = data
      ) do
    {:next_state, {:connected, connection}, data}
  end

  # Connection status events; when we go offline we should transition
  # into the disconnected state. Everything else will get ignored.
  def handle_event(
        :info,
        {{Tortoise, client_id}, :status, :down},
        _current_state,
        %State{client_id: client_id} = data
      ) do
    {:next_state, :disconnected, data}
  end

  def handle_event(:info, {{Tortoise, _}, :status, _}, _, %State{}) do
    :keep_state_and_data
  end

  # create
  def handle_event(:cast, {:incoming, package}, _state, data) do
    track = Track.create(:positive, package)
    updated_pending = Map.put_new(data.pending, track.identifier, track)

    next_actions = [
      {:next_event, :internal, {:execute, track}}
    ]

    {:keep_state, %State{data | pending: updated_pending}, next_actions}
  end

  def handle_event(:cast, {:outgoing, caller, package}, _state, data) do
    {:ok, package} = assign_identifier(package, data.pending)
    track = Track.create({:negative, caller}, package)
    updated_pending = Map.put_new(data.pending, track.identifier, track)

    next_actions = [
      {:next_event, :internal, {:execute, track}}
    ]

    {:keep_state, %State{data | pending: updated_pending}, next_actions}
  end

  # update
  def handle_event(
        :cast,
        {:update, {_, %{identifier: identifier}} = update},
        _state,
        %State{pending: pending} = data
      ) do
    with {:ok, track} <- Map.fetch(pending, identifier),
         {:ok, track} <- Track.resolve(track, update) do
      next_actions = [
        {:next_event, :internal, {:execute, track}}
      ]

      data = %State{data | pending: Map.put(pending, identifier, track)}

      {:keep_state, data, next_actions}
    else
      :error ->
        {:stop, {:protocol_violation, :unknown_identifier}, data}

      {:error, reason} ->
        {:stop, reason, data}
    end
  end

  def handle_event(
        :internal,
        {:execute, %Track{pending: [[{:dispatch, package}, _] | _]} = track},
        {:connected, {transport, socket}},
        %State{} = data
      ) do
    case apply(transport, :send, [socket, Package.encode(package)]) do
      :ok ->
        {:keep_state, handle_next(track, data)}
    end
  end

  def handle_event(
        :internal,
        {:execute, %Track{pending: [[{:dispatch, _}, _] | _]}},
        :disconnected,
        %State{}
      ) do
    :keep_state_and_data
  end

  def handle_event(
        :internal,
        {:execute, %Track{pending: [[{:respond, caller}, _] | _]} = track},
        _state,
        %State{client_id: client_id} = data
      ) do
    case Track.result(track) do
      {:ok, result} ->
        :ok = Controller.handle_result(client_id, {caller, track.type, result})
        {:keep_state, handle_next(track, data)}
    end
  end

  # helpers ------------------------------------------------------------
  defp handle_next(
         %Track{pending: [[_, :cleanup]], identifier: identifier},
         %State{pending: pending} = state
       ) do
    %State{state | pending: Map.delete(pending, identifier)}
  end

  defp handle_next(_track, %State{} = state) do
    state
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
