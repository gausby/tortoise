defmodule Tortoise311.Connection.Controller do
  @moduledoc false

  use GenServer

  alias __MODULE__, as: State
  alias Tortoise311.Connection.Inflight
  alias Tortoise311.{Connection, Handler, Package}

  alias Tortoise311.Package.{
    Connack,
    Connect,
    Disconnect,
    Pingreq,
    Pingresp,
    Puback,
    Pubcomp,
    Publish,
    Pubrec,
    Pubrel,
    Suback,
    Subscribe,
    Unsuback,
    Unsubscribe
  }

  require Logger

  @enforce_keys [:client_id, :handler]
  defstruct client_id: nil,
            ping: :queue.new(),
            status: :down,
            awaiting: %{},
            handler: %Handler{module: Handler.Default, initial_args: []}

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    handler = Handler.new(Keyword.fetch!(opts, :handler))

    init_state = %State{
      client_id: client_id,
      handler: handler
    }

    GenServer.start_link(__MODULE__, init_state, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise311.Registry.via_name(__MODULE__, client_id)
  end

  # This is sent just before the Controller's supervisor is shutdown.
  # All we want to do here is disable the controller until it is terminated by its supervisor shutting down.
  def stop(client_id) do
    GenServer.cast(via_name(client_id), :stop)
  end

  def info(client_id) do
    GenServer.call(via_name(client_id), :info)
  end

  @spec ping(Tortoise311.client_id()) :: {:ok, reference()}
  def ping(client_id) do
    ref = make_ref()
    :ok = GenServer.cast(via_name(client_id), {:ping, {self(), ref}})
    {:ok, ref}
  end

  @spec ping_sync(Tortoise311.client_id(), timeout()) ::
          {:ok, reference()} | {:error, :timeout}
  def ping_sync(client_id, timeout \\ Tortoise311.default_timeout()) do
    {:ok, ref} = ping(client_id)

    receive do
      {Tortoise311, {:ping_response, ^ref, round_trip_time}} ->
        {:ok, round_trip_time}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc false
  def handle_incoming(client_id, package) do
    GenServer.cast(via_name(client_id), {:incoming, package})
  end

  @doc false
  def handle_result(client_id, {{pid, ref}, Package.Publish, result}) do
    send(pid, {{Tortoise311, client_id}, ref, result})
    :ok
  end

  def handle_result(client_id, {{pid, ref}, type, result}) do
    send(pid, {{Tortoise311, client_id}, ref, result})
    GenServer.cast(via_name(client_id), {:result, {type, result}})
  end

  @doc false
  def handle_onward(client_id, %Package.Publish{} = publish) do
    GenServer.cast(via_name(client_id), {:onward, publish})
  end

  # Server callbacks
  @impl GenServer
  def init(%State{handler: handler} = opts) do
    {:ok, _} = Tortoise311.Events.register(opts.client_id, :status)
    {:ok, _} = Tortoise311.Events.register(opts.client_id, :connection)

    case Handler.execute(handler, :init) do
      {:ok, %Handler{} = updated_handler} ->
        {:ok, %State{opts | handler: updated_handler}}
    end
  end

  @impl GenServer
  def terminate(reason, %State{handler: handler}) do
    _ignored = Handler.execute(handler, {:terminate, reason})
    :ok
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer

  def handle_cast(_, %State{status: :stopped} = state), do: {:noreply, state}

  def handle_cast(:stop, state), do: {:noreply, %State{state | status: :stopped}}

  def handle_cast({:incoming, <<package::binary>>}, state) do
    package
    |> Package.decode()
    |> handle_package(state)
  end

  # allow for passing in already decoded packages into the controller,
  # this allow us to test the controller without having to pass in
  # binaries
  def handle_cast({:incoming, %{:__META__ => _} = package}, state) do
    handle_package(package, state)
  end

  def handle_cast({:ping, caller}, state) do
    with {:ok, {transport, socket}} <- Connection.connection(state.client_id) do
      time = System.monotonic_time(:microsecond)
      apply(transport, :send, [socket, Package.encode(%Package.Pingreq{})])
      ping = :queue.in({caller, time}, state.ping)
      {:noreply, %State{state | ping: ping}}
    else
      {:error, :unknown_connection} ->
        {:stop, :unknown_connection, state}
    end
  end

  def handle_cast(
        {:result, {Package.Subscribe, subacks}},
        %State{handler: handler} = state
      ) do
    if state.status != :stopped do
      case Handler.execute(handler, {:subscribe, subacks}) do
        {:ok, updated_handler} ->
          {:noreply, %State{state | handler: updated_handler}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_cast(
        {:result, {Package.Unsubscribe, unsubacks}},
        %State{handler: handler} = state
      ) do
    if state.status != :stopped do
      case Handler.execute(handler, {:unsubscribe, unsubacks}) do
        {:ok, updated_handler} ->
          {:noreply, %State{state | handler: updated_handler}}
      end
    else
      {:noreply, state}
    end
  end

  # an incoming publish with QoS=2 will get parked in the inflight
  # manager process, which will onward it to the controller, making
  # sure we will only dispatch it once to the publish-handler.
  def handle_cast(
        {:onward, %Package.Publish{qos: 2, dup: false} = publish},
        %State{handler: handler} = state
      ) do
    if state.status != :stopped do
      case Handler.execute(handler, {:publish, publish}) do
        {:ok, updated_handler} ->
          {:noreply, %State{state | handler: updated_handler}}
      end
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(_, %State{status: :stopped} = state), do: {:noreply, state}

  def handle_info({:next_action, {:subscribe, topic, opts} = action}, state) do
    {qos, opts} = Keyword.pop_first(opts, :qos, 0)

    case Tortoise311.Connection.subscribe(state.client_id, [{topic, qos}], opts) do
      {:ok, ref} ->
        updated_awaiting = Map.put_new(state.awaiting, ref, action)
        {:noreply, %State{state | awaiting: updated_awaiting}}
    end
  end

  def handle_info({:next_action, {:unsubscribe, topic} = action}, state) do
    case Tortoise311.Connection.unsubscribe(state.client_id, topic) do
      {:ok, ref} ->
        updated_awaiting = Map.put_new(state.awaiting, ref, action)
        {:noreply, %State{state | awaiting: updated_awaiting}}
    end
  end

  # connection changes
  def handle_info(
        {{Tortoise311, client_id}, :status, same},
        %State{client_id: client_id, status: same} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {{Tortoise311, client_id}, :status, new_status},
        %State{client_id: client_id, handler: handler} = state
      ) do
    case Handler.execute(handler, {:connection, new_status}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler, status: new_status}}
    end
  end

  def handle_info(
        {{Tortoise311, client_id}, :connection, {server, socket}},
        %State{client_id: client_id, handler: handler} = state
      ) do
    case Handler.execute(handler, {:connected, server, socket}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}
    end
  end

  def handle_info({{Tortoise311, client_id}, ref, result}, %{client_id: client_id} = state) do
    case {result, Map.pop(state.awaiting, ref)} do
      {_, {nil, _}} ->
        Logger.warning("Unexpected async result")
        {:noreply, state}

      {:ok, {_action, updated_awaiting}} ->
        {:noreply, %State{state | awaiting: updated_awaiting}}
    end
  end

  # QoS LEVEL 0 ========================================================
  # commands -----------------------------------------------------------
  defp handle_package(
         %Publish{qos: 0, dup: false} = publish,
         %State{handler: handler} = state
       ) do
    case Handler.execute(handler, {:publish, publish}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}

        # handle stop
    end
  end

  # QoS LEVEL 1 ========================================================
  # commands -----------------------------------------------------------
  defp handle_package(
         %Publish{qos: 1} = publish,
         %State{handler: handler} = state
       ) do
    :ok = Inflight.track(state.client_id, {:incoming, publish})

    case Handler.execute(handler, {:publish, publish}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}
    end
  end

  # response -----------------------------------------------------------
  defp handle_package(%Puback{} = puback, state) do
    :ok = Inflight.update(state.client_id, {:received, puback})
    {:noreply, state}
  end

  # QoS LEVEL 2 ========================================================
  # commands -----------------------------------------------------------
  defp handle_package(%Publish{qos: 2} = publish, %State{} = state) do
    :ok = Inflight.track(state.client_id, {:incoming, publish})
    {:noreply, state}
  end

  defp handle_package(%Pubrel{} = pubrel, state) do
    :ok = Inflight.update(state.client_id, {:received, pubrel})
    {:noreply, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Pubrec{} = pubrec, state) do
    :ok = Inflight.update(state.client_id, {:received, pubrec})
    {:noreply, state}
  end

  defp handle_package(%Pubcomp{} = pubcomp, state) do
    :ok = Inflight.update(state.client_id, {:received, pubcomp})
    {:noreply, state}
  end

  # SUBSCRIBING ========================================================
  # command ------------------------------------------------------------
  defp handle_package(%Subscribe{} = subscribe, state) do
    # not a server! (yet)
    {:stop, {:protocol_violation, {:unexpected_package_from_remote, subscribe}}, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Suback{} = suback, state) do
    :ok = Inflight.update(state.client_id, {:received, suback})
    {:noreply, state}
  end

  # UNSUBSCRIBING ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Unsubscribe{} = unsubscribe, state) do
    # not a server
    {:stop, {:protocol_violation, {:unexpected_package_from_remote, unsubscribe}}, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Unsuback{} = unsuback, state) do
    :ok = Inflight.update(state.client_id, {:received, unsuback})
    {:noreply, state}
  end

  # PING MESSAGES ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Pingresp{}, %State{ping: ping} = state)
       when is_nil(ping) or ping == {[], []} do
    {:noreply, state}
  end

  defp handle_package(%Pingresp{}, %State{ping: ping} = state) do
    {{:value, {{caller, ref}, start_time}}, ping} = :queue.out(ping)
    round_trip_time = System.monotonic_time(:microsecond) - start_time
    send(caller, {Tortoise311, {:ping_response, ref, round_trip_time}})
    {:noreply, %State{state | ping: ping}}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Pingreq{} = pingreq, state) do
    # not a server!
    {:stop, {:protocol_violation, {:unexpected_package_from_remote, pingreq}}, state}
  end

  # CONNECTING =========================================================
  # command ------------------------------------------------------------
  defp handle_package(%Connect{} = connect, state) do
    # not a server!
    {:stop, {:protocol_violation, {:unexpected_package_from_remote, connect}}, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Connack{} = connack, state) do
    # receiving a connack at this point would be a protocol violation
    {:stop, {:protocol_violation, {:unexpected_package_from_remote, connack}}, state}
  end

  # DISCONNECTING ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Disconnect{} = disconnect, state) do
    # This should be allowed when we implement MQTT 5. Remember there
    # is a test that assert this as a protocol violation!
    {:stop, {:protocol_violation, {:unexpected_package_from_remote, disconnect}}, state}
  end
end
