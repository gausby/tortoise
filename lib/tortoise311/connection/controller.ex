defmodule Tortoise311.Connection.Controller do
  @moduledoc false

  require Logger

  alias Tortoise311.{Package, Connection, Handler}
  alias Tortoise311.Connection.Inflight

  alias Tortoise311.Package.{
    Connect,
    Connack,
    Disconnect,
    Publish,
    Puback,
    Pubrec,
    Pubrel,
    Pubcomp,
    Subscribe,
    Suback,
    Unsubscribe,
    Unsuback,
    Pingreq,
    Pingresp
  }

  use GenServer

  @enforce_keys [:client_id, :handler]
  defstruct client_id: nil,
            ping: :queue.new(),
            status: :down,
            awaiting: %{},
            handler: %Handler{module: Handler.Default, initial_args: []}

  alias __MODULE__, as: State

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

  def stop(client_id) do
    GenServer.stop(via_name(client_id))
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

  @spec ping_sync(Tortoise311.client_id(), timeout() | nil) ::
          {:ok, reference()} | {:error, :timeout}
  def ping_sync(client_id, timeout \\ nil) do
    {:ok, ref} = ping(client_id)
    timeout = timeout || Tortoise311.default_timeout()

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
  @impl true
  def init(%State{handler: handler} = opts) do
    {:ok, _} = Tortoise311.Events.register(opts.client_id, :status)

    case Handler.execute(handler, :init) do
      {:ok, %Handler{} = updated_handler} ->
        {:ok, %State{opts | handler: updated_handler}}
    end
  end

  @impl true
  def terminate(reason, %State{handler: handler}) do
    _ignored = Handler.execute(handler, {:terminate, reason})
    :ok
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, state, state}
  end

  @impl true
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
    case Handler.execute(handler, {:subscribe, subacks}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}
    end
  end

  def handle_cast(
        {:result, {Package.Unsubscribe, unsubacks}},
        %State{handler: handler} = state
      ) do
    case Handler.execute(handler, {:unsubscribe, unsubacks}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}
    end
  end

  # an incoming publish with QoS=2 will get parked in the inflight
  # manager process, which will onward it to the controller, making
  # sure we will only dispatch it once to the publish-handler.
  def handle_cast(
        {:onward, %Package.Publish{qos: 2, dup: false} = publish},
        %State{handler: handler} = state
      ) do
    case Handler.execute(handler, {:publish, publish}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}
    end
  end

  @impl true
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

  def handle_info({{Tortoise311, client_id}, ref, result}, %{client_id: client_id} = state) do
    case {result, Map.pop(state.awaiting, ref)} do
      {_, {nil, _}} ->
        Logger.warn("Unexpected async result")
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
