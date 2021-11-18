defmodule Tortoise311.Connection.Inflight do
  @moduledoc false

  alias Tortoise311.{Package, Connection}
  alias Tortoise311.Connection.Controller
  alias Tortoise311.Connection.Inflight.Track

  use GenStateMachine

  @enforce_keys [:client_id]
  defstruct client_id: nil, pending: %{}, order: []

  alias __MODULE__, as: State

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    GenStateMachine.start_link(__MODULE__, opts, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise311.Registry.via_name(__MODULE__, client_id)
  end

  def stop(client_id) do
    GenStateMachine.stop(via_name(client_id))
  end

  @doc false
  def drain(client_id) do
    GenStateMachine.call(via_name(client_id), :drain)
  end

  @doc false
  def track(client_id, {:incoming, %Package.Publish{qos: qos} = publish})
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

  @doc false
  def track_sync(client_id, {:outgoing, _} = command, timeout \\ :infinity) do
    {:ok, ref} = track(client_id, command)

    receive do
      {{Tortoise311, ^client_id}, ^ref, result} ->
        result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc false
  def update(client_id, {_, %{__struct__: _, identifier: _identifier}} = event) do
    :ok = GenStateMachine.cast(via_name(client_id), {:update, event})
  end

  @doc false
  def reset(client_id) do
    :ok = GenStateMachine.cast(via_name(client_id), :reset)
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
        {:ok, _} = Tortoise311.Events.register(data.client_id, :status)
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
        {{Tortoise311, client_id}, :connection, connection},
        _current_state,
        %State{client_id: client_id, pending: pending} = data
      ) do
    next_actions =
      for identifier <- Enum.reverse(data.order) do
        case Map.get(pending, identifier, :unknown) do
          %Track{pending: [[{:dispatch, %Package.Publish{} = publish} | action] | pending]} =
              track ->
            publish = %Package.Publish{publish | dup: true}
            track = %Track{track | pending: [[{:dispatch, publish} | action] | pending]}
            {:next_event, :internal, {:execute, track}}

          %Track{} = track ->
            {:next_event, :internal, {:execute, track}}
        end
      end

    {:next_state, {:connected, connection}, data, next_actions}
  end

  # Connection status events; when we go offline we should transition
  # into the disconnected state. Everything else will get ignored.
  def handle_event(
        :info,
        {{Tortoise311, client_id}, :status, :down},
        _current_state,
        %State{client_id: client_id} = data
      ) do
    {:next_state, :disconnected, data}
  end

  def handle_event(:info, {{Tortoise311, _}, :status, _}, _, %State{}) do
    :keep_state_and_data
  end

  # Create. Notice: we will only receive publish packages from the
  # remote; everything else is something we initiate
  def handle_event(
        :cast,
        {:incoming, %Package.Publish{dup: false} = package},
        _state,
        %State{pending: pending} = data
      ) do
    track = Track.create(:positive, package)

    data = %State{
      data
      | pending: Map.put_new(pending, track.identifier, track),
        order: [track.identifier | data.order]
    }

    next_actions = [
      {:next_event, :internal, {:onward_publish, package}},
      {:next_event, :internal, {:execute, track}}
    ]

    {:keep_state, data, next_actions}
  end

  # possible duplicate
  def handle_event(:cast, {:incoming, _}, :draining, %State{}) do
    :keep_state_and_data
  end

  def handle_event(
        :cast,
        {:incoming, %Package.Publish{identifier: identifier, dup: true} = publish},
        _state,
        %State{pending: pending} = data
      ) do
    case Map.get(pending, identifier) do
      nil ->
        next_actions = [
          {:next_event, :cast, {:incoming, %Package.Publish{publish | dup: false}}}
        ]

        {:keep_state_and_data, next_actions}

      %Track{polarity: :positive, status: [{:received, %{__struct__: Package.Publish}}]} ->
        :keep_state_and_data

      _otherwise ->
        {:stop, :state_out_of_sync, data}
    end
  end

  def handle_event(:cast, {:outgoing, {pid, ref}, _}, :draining, data) do
    send(pid, {{Tortoise311, data.client_id}, ref, {:error, :terminating}})
    :keep_state_and_data
  end

  def handle_event(:cast, {:outgoing, caller, package}, _state, data) do
    {:ok, package} = assign_identifier(package, data.pending)
    track = Track.create({:negative, caller}, package)

    next_actions = [
      {:next_event, :internal, {:execute, track}}
    ]

    data = %State{
      data
      | pending: Map.put_new(data.pending, track.identifier, track),
        order: [track.identifier | data.order]
    }

    {:keep_state, data, next_actions}
  end

  # update
  def handle_event(:cast, {:update, _}, :draining, _data) do
    :keep_state_and_data
  end

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

      data = %State{
        data
        | pending: Map.put(pending, identifier, track),
          order: [identifier | data.order -- [identifier]]
      }

      {:keep_state, data, next_actions}
    else
      :error ->
        {:stop, {:protocol_violation, :unknown_identifier}, data}

      {:error, reason} ->
        {:stop, reason, data}
    end
  end

  def handle_event(:cast, :reset, _, %State{pending: pending} = data) do
    # cancel all currently outgoing messages
    for {_, %Track{polarity: :negative, caller: {pid, ref}}} <- pending do
      send(pid, {{Tortoise311, data.client_id}, ref, {:error, :canceled}})
    end

    {:keep_state, %State{data | pending: %{}, order: []}}
  end

  # We trap the incoming QoS 2 packages in the inflight manager so we
  # can make sure we will not onward them to the connection handler
  # more than once.
  def handle_event(
        :internal,
        {:onward_publish, %Package.Publish{qos: 2} = publish},
        _,
        %State{} = data
      ) do
    :ok = Controller.handle_onward(data.client_id, publish)
    :keep_state_and_data
  end

  # The other package types should not get onwarded to the controller
  # handler
  def handle_event(:internal, {:onward_publish, _}, _, %State{}) do
    :keep_state_and_data
  end

  def handle_event(:internal, {:execute, _}, :draining, _) do
    :keep_state_and_data
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
    # the dispatch will get re-queued when we regain the connection
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

  def handle_event({:call, from}, :drain, {:connected, {transport, socket}}, %State{} = data) do
    for {_, %Track{polarity: :negative, caller: {pid, ref}}} <- data.pending do
      send(pid, {{Tortoise311, data.client_id}, ref, {:error, :canceled}})
    end

    data = %State{data | pending: %{}, order: []}
    disconnect = %Package.Disconnect{}

    case apply(transport, :send, [socket, Package.encode(disconnect)]) do
      :ok ->
        :ok = transport.close(socket)
        reply = {:reply, from, :ok}
        {:next_state, :draining, data, reply}
    end
  end

  # helpers ------------------------------------------------------------
  defp handle_next(
         %Track{pending: [[_, :cleanup]], identifier: identifier},
         %State{pending: pending} = state
       ) do
    order = state.order -- [identifier]
    %State{state | pending: Map.delete(pending, identifier), order: order}
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
