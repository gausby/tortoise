defmodule Tortoise.Connection.Inflight do
  @moduledoc false

  alias Tortoise.{Package, Connection}
  alias Tortoise.Connection.Inflight.Track

  use GenStateMachine

  @enforce_keys [:client_id, :parent]
  defstruct client_id: nil, parent: nil, pending: %{}, order: []

  alias __MODULE__, as: State

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    GenStateMachine.start_link(__MODULE__, opts, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def whereis(client_id) do
    __MODULE__
    |> Tortoise.Registry.reg_name(client_id)
    |> Registry.whereis_name()
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
    # no transforms and nil track session state
    track(client_id, {:outgoing, package, {[], nil}})
  end

  def track(client_id, {:outgoing, package, opts}) do
    caller = {_, ref} = {self(), make_ref()}

    case package do
      %Package.Publish{qos: qos} when qos in [1, 2] ->
        :ok = GenStateMachine.cast(via_name(client_id), {:outgoing, caller, {package, opts}})
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
  def track_sync(client_id, command, timeout \\ :infinity)

  def track_sync(client_id, {:outgoing, %Package.Publish{}} = command, timeout) do
    # add no transforms and a nil track state
    track_sync(client_id, Tuple.append(command, {[], nil}), timeout)
  end

  def track_sync(client_id, {:outgoing, %Package.Publish{}, _transforms} = command, timeout) do
    {:ok, ref} = track(client_id, command)

    receive do
      {{Tortoise, ^client_id}, {Package.Publish, ^ref}, result} ->
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
    parent_pid = Keyword.fetch!(opts, :parent)
    initial_data = %State{client_id: client_id, parent: parent_pid}

    next_actions = [
      {:next_event, :internal, :post_init}
    ]

    {:ok, _} = Tortoise.Events.register(client_id, :status)

    {:ok, :disconnected, initial_data, next_actions}
  end

  @impl true
  def handle_event(:internal, :post_init, :disconnected, data) do
    case Connection.connection(data.client_id, active: true) do
      {:ok, {_transport, _socket} = connection} ->
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
        {{Tortoise, client_id}, :status, :down},
        _current_state,
        %State{client_id: client_id} = data
      ) do
    {:next_state, :disconnected, data}
  end

  def handle_event(:info, {{Tortoise, _}, :status, _}, _, %State{}) do
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
      {:next_event, :internal, {:onward_publish, package}}
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
    send(pid, {{Tortoise, data.client_id}, ref, {:error, :terminating}})
    :keep_state_and_data
  end

  def handle_event(:cast, {:outgoing, caller, {package, opts}}, _state, data) do
    {:ok, package} = assign_identifier(package, data.pending)
    track = Track.create({:negative, caller}, {package, opts})

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
        {:update, {:received, %{identifier: identifier} = package} = update},
        _state,
        %State{pending: pending} = data
      ) do
    with {:ok, track} <- Map.fetch(pending, identifier),
         {_package, track} = apply_transform(package, track),
         {:ok, track} <- Track.resolve(track, update) do
      data = %State{
        data
        | pending: Map.put(pending, identifier, track),
          order: [identifier | data.order -- [identifier]]
      }

      case track do
        %Track{pending: [[{:respond, _}, _] | _]} ->
          next_actions = [
            {:next_event, :internal, {:execute, track}}
          ]

          {:keep_state, data, next_actions}

        # to support user defined properties we need to await a
        # dispatch command from the controller before we can
        # progress.
        %Track{pending: [[{:dispatch, _}, _] | _]} ->
          {:keep_state, data}
      end
    else
      :error ->
        {:stop, {:protocol_violation, :unknown_identifier}, data}

      {:error, reason} ->
        {:stop, reason, data}
    end
  end

  def handle_event(
        :cast,
        {:update, {:dispatch, %{identifier: identifier}} = update},
        _state,
        %State{pending: pending} = data
      ) do
    with {:ok, track} <- Map.fetch(pending, identifier),
         {:ok, track} <- Track.resolve(track, update) do
      data = %State{
        data
        | pending: Map.put(pending, identifier, track),
          order: [identifier | data.order -- [identifier]]
      }

      next_actions = [
        {:next_event, :internal, {:execute, track}}
      ]

      {:keep_state, data, next_actions}
    end
  end

  def handle_event(:cast, :reset, _, %State{pending: pending} = data) do
    # cancel all currently outgoing messages
    for {_, %Track{polarity: :negative, caller: {pid, ref}}} <- pending do
      send(pid, {{Tortoise, data.client_id}, ref, {:error, :canceled}})
    end

    {:keep_state, %State{data | pending: %{}, order: []}}
  end

  # We trap the incoming QoS>0 packages in the inflight manager so we
  # can make sure we will not onward the same publish to the user
  # defined callback more than once.
  def handle_event(
        :internal,
        {:onward_publish, %Package.Publish{qos: qos} = publish},
        _,
        %State{client_id: client_id, parent: parent_pid}
      )
      when qos in 1..2 do
    send(parent_pid, {{__MODULE__, client_id}, publish})
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
    with {package, track} <- apply_transform(package, track),
         :ok = apply(transport, :send, [socket, Package.encode(package)]) do
      {:keep_state, handle_next(track, data)}
    else
      res ->
        {:stop, res, data}
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
        {:execute, %Track{pending: [[{:respond, {pid, ref}}, _] | _]} = track},
        _state,
        %State{client_id: client_id} = data
      ) do
    case Track.result(track) do
      {:ok, result} ->
        send(pid, {{Tortoise, client_id}, {track.type, ref}, result})
        {:keep_state, handle_next(track, data)}
    end
  end

  def handle_event({:call, from}, :drain, {:connected, {transport, socket}}, %State{} = data) do
    for {_, %Track{polarity: :negative, caller: {pid, ref}}} <- data.pending do
      send(pid, {{Tortoise, data.client_id}, ref, {:error, :canceled}})
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
  @type_to_cb %{
    Package.Publish => :publish,
    Package.Pubrec => :pubrec,
    Package.Pubrel => :pubrel,
    Package.Pubcomp => :pubcomp,
    Package.Puback => :puback
  }

  defp apply_transform(package, %Track{transforms: []} = track) do
    # noop, no transforms defined for any package type, so just pass
    # through
    {package, track}
  end

  defp apply_transform(%type{identifier: identifier} = package, %Track{} = track) do
    # see if the callback for the given type is defined; if so, apply
    # it and update the track state
    case track.transforms[Map.get(@type_to_cb, type)] do
      nil ->
        {package, track}

      fun when is_function(fun) ->
        case apply(fun, [package, track.state]) do
          {:ok, updated_state} ->
            # just update the track session state
            updated_track_state = %Track{track | state: updated_state}
            {package, updated_track_state}

          {:ok, properties, updated_state} when is_list(properties) ->
            # Update the user defined properties on the package with a
            # list of `[{string, string}]`
            updated_package = %{package | properties: properties}
            updated_track_state = %Track{track | state: updated_state}
            {updated_package, updated_track_state}

          {:ok, %^type{identifier: ^identifier} = updated_package, updated_state} ->
            # overwrite the package with a package of the same type
            # and identifier; allows us to alter properties besides
            # the user defined properties
            updated_track_state = %Track{track | state: updated_state}
            {updated_package, updated_track_state}
        end
    end
  end

  defp handle_next(
         %Track{pending: [[_, :cleanup]], identifier: identifier},
         %State{pending: pending} = state
       ) do
    order = state.order -- [identifier]
    %State{state | pending: Map.delete(pending, identifier), order: order}
  end

  defp handle_next(%Track{identifier: identifier} = track, %State{pending: pending} = state) do
    %State{state | pending: Map.replace!(pending, identifier, track)}
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
