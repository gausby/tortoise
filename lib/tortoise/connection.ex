defmodule Tortoise.Connection do
  @moduledoc false
  use GenServer

  require Logger

  defstruct [:connect, :server, :session, :subscriptions, :keep_alive]
  alias __MODULE__, as: State

  @type client_id() :: binary() | atom()

  alias Tortoise.{Transport, Connection, Package}
  alias Tortoise.Connection.{Inflight, Controller, Receiver, Transmitter}
  alias Tortoise.Package.{Connect, Connack}

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    server = opts |> Keyword.fetch!(:server) |> coerce_server()

    connect = %Package.Connect{
      client_id: client_id,
      user_name: Keyword.get(opts, :user_name),
      password: Keyword.get(opts, :password),
      keep_alive: Keyword.get(opts, :keep_alive, 60),
      will: Keyword.get(opts, :last_will),
      # if we re-spawn from here it means our state is gone
      clean_session: true
    }

    subscriptions =
      case Keyword.get(opts, :subscriptions, []) do
        topics when is_list(topics) ->
          Enum.into(topics, %Package.Subscribe{})

        %Package.Subscribe{} = subscribe ->
          subscribe
      end

    # @todo, validate that the handler is valid
    opts = Keyword.take(opts, [:client_id, :handler])
    initial = {server, connect, subscriptions, opts}
    GenServer.start_link(__MODULE__, initial, name: via_name(client_id))
  end

  def via_name(pid) when is_pid(pid), do: pid

  def via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  defp coerce_server({:tcp, host, port}) do
    opts = [:binary, packet: :raw, active: false]
    %Transport{type: Transport.Tcp, host: host, port: port, opts: opts}
  end

  defp coerce_server({:ssl, host, port, opts}) do
    opts = [:binary, {:packet, :raw}, {:active, false} | opts]
    %Transport{type: Transport.SSL, host: host, port: port, opts: opts}
  end

  # Public interface
  def publish(client_id, topic, payload \\ nil, opts \\ []) do
    qos = Keyword.get(opts, :qos, 0)

    publish = %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    case publish do
      %Package.Publish{qos: 0} ->
        Transmitter.cast(client_id, publish)

      %Package.Publish{qos: qos} when qos in [1, 2] ->
        Inflight.track(client_id, {:outgoing, publish})
    end
  end

  def publish_sync(client_id, topic, payload \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    qos = Keyword.get(opts, :qos, 0)

    publish = %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    case publish do
      %Package.Publish{qos: 0} ->
        Transmitter.cast(client_id, publish)

      %Package.Publish{qos: qos} when qos in [1, 2] ->
        Inflight.track_sync(client_id, {:outgoing, publish}, timeout)
    end
  end

  # subscribe/unsubscribe
  def subscribe(client_id, topics, opts \\ [])

  def subscribe(client_id, [{_, n} | _] = topics, opts) when is_number(n) do
    identifier = Keyword.get(opts, :identifier, nil)
    subscribe = Enum.into(topics, %Package.Subscribe{identifier: identifier})
    GenServer.call(via_name(client_id), {:subscribe, subscribe})
  end

  def subscribe(client_id, {_, n} = topic, opts) when is_number(n) do
    subscribe(client_id, [topic], opts)
  end

  def unsubscribe(client_id, topics, opts \\ [])

  def unsubscribe(client_id, topics, opts) when is_list(topics) do
    identifier = Keyword.get(opts, :identifier, nil)
    unsubscribe = %Package.Unsubscribe{identifier: identifier, topics: topics}
    GenServer.call(via_name(client_id), {:unsubscribe, unsubscribe})
  end

  def unsubscribe(client_id, topic, opts) when is_binary(topic) do
    unsubscribe(client_id, [topic], opts)
  end

  def subscriptions(client_id) do
    GenServer.call(via_name(client_id), :subscriptions)
  end

  @doc false
  @spec renew(client_id()) :: :ok
  def renew(client_id) do
    GenServer.cast(via_name(client_id), :renew_connection)
  end

  # Callbacks
  def init({transport, %Connect{} = connect, subscriptions, opts}) do
    expected_connack = %Connack{status: :accepted, session_present: false}

    with {^expected_connack, socket} <- do_connect(transport, connect),
         {:ok, pid} = Connection.Supervisor.start_link(opts),
         :ok = Receiver.handle_socket(connect.client_id, {transport.type, socket}),
         :ok = Controller.update_connection_status(connect.client_id, :up) do
      if not Enum.empty?(subscriptions), do: send(self(), :subscribe)

      result = %State{
        session: pid,
        server: transport,
        connect: connect,
        subscriptions: subscriptions
      }

      {:ok, reset_keep_alive(result)}
    else
      %Connack{status: {:refused, reason}} ->
        {:stop, {:connection_failed, reason}}

      {:error, {:protocol_violation, violation}} ->
        Logger.error("Protocol violation: #{inspect(violation)}")
        {:stop, :protocol_violation}
    end
  end

  def handle_info(:subscribe, %State{subscriptions: subscriptions} = state) do
    client_id = state.connect.client_id

    case Enum.empty?(subscriptions) do
      true ->
        # nothing to subscribe to, just continue
        {:noreply, state}

      false ->
        # subscribe to the predefined topics
        case Inflight.track_sync(client_id, {:outgoing, subscriptions}, 5000) do
          {:error, :timeout} ->
            {:stop, :subscription_timeout, state}

          result ->
            case handle_suback_result(result, state) do
              {:ok, updated_state} ->
                {:noreply, updated_state}

              {:error, reasons} ->
                error = {:unable_to_subscribe, reasons}
                {:stop, error, state}
            end
        end
    end
  end

  def handle_info(:ping, %State{} = state) do
    case Controller.ping_sync(state.connect.client_id, 5000) do
      {:ok, round_trip_time} ->
        Logger.debug("Ping: #{round_trip_time} μs")
        state = reset_keep_alive(state)
        {:noreply, state}

      {:error, :timeout} ->
        {:stop, :ping_timeout, state}
    end
  end

  # dropping connection
  def handle_info({transport, _socket}, state) when transport in [:tcp_closed, :ssl_closed] do
    Logger.error("Socket closed before we handed it to the receiver")
    :ok = Controller.update_connection_status(state.connect.client_id, :down)
    do_attempt_reconnect(state)
  end

  def handle_cast(:renew_connection, state) do
    :ok = Controller.update_connection_status(state.connect.client_id, :down)
    do_attempt_reconnect(state)
  end

  # subscribing
  def handle_call({:subscribe, subscribe}, from, state) do
    client_id = state.connect.client_id

    case Inflight.track_sync(client_id, {:outgoing, subscribe}, 5000) do
      {:error, :timeout} = error ->
        {:reply, error, state}

      result ->
        case handle_suback_result(result, state) do
          {:ok, updated_state} ->
            {:reply, :ok, updated_state}

          {:error, reasons} ->
            error = {:unable_to_subscribe, reasons}
            GenServer.reply(from, {:error, error})
            {:stop, error, state}
        end
    end
  end

  def handle_call({:unsubscribe, unsubscribe}, _from, state) do
    client_id = state.connect.client_id

    case Inflight.track_sync(client_id, {:outgoing, unsubscribe}, 5000) do
      {:error, :timeout} = error ->
        {:reply, error, state}

      unsubbed ->
        topics = Keyword.drop(state.subscriptions.topics, unsubbed)
        subscriptions = %Package.Subscribe{state.subscriptions | topics: topics}
        {:reply, :ok, %State{state | subscriptions: subscriptions}}
    end
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  # Helpers
  defp handle_suback_result(%{:error => []} = results, %State{} = state) do
    subscriptions = Enum.into(results[:ok], state.subscriptions)
    {:ok, %State{state | subscriptions: subscriptions}}
  end

  defp handle_suback_result(%{:error => errors}, %State{}) do
    {:error, errors}
  end

  defp reset_keep_alive(%State{keep_alive: nil} = state) do
    ref = Process.send_after(self(), :ping, state.connect.keep_alive * 1000)
    %State{state | keep_alive: ref}
  end

  defp reset_keep_alive(%State{keep_alive: previous_ref} = state) do
    # Cancel the previous timer, just in case one was already set
    _ = Process.cancel_timer(previous_ref)
    ref = Process.send_after(self(), :ping, state.connect.keep_alive * 1000)
    %State{state | keep_alive: ref}
  end

  defp do_connect(server, %Connect{} = connect) do
    %{type: transport, host: host, port: port, opts: opts} = server

    with {:ok, socket} <- transport.connect(host, port, opts),
         :ok = transport.send(socket, Package.encode(connect)),
         {:ok, packet} <- transport.recv(socket, 4, 5000) do
      case Package.decode(packet) do
        %Connack{status: :accepted} = connack ->
          {connack, socket}

        %Connack{status: {:refused, _reason}} = connack ->
          connack

        other ->
          violation = %{expected: Connect, got: other}
          {:error, {:protocol_violation, violation}}
      end
    else
      {:error, :econnrefused} ->
        {:error, {:connection_refused, host, port}}
    end
  end

  defp do_attempt_reconnect(%State{server: transport} = state) do
    connect = %Connect{state.connect | clean_session: false}

    with {%Connack{status: :accepted} = connack, socket} <- do_connect(transport, connect),
         :ok = Receiver.handle_socket(connect.client_id, {transport.type, socket}),
         :ok = Controller.update_connection_status(connect.client_id, :up) do
      case connack do
        %Connack{session_present: true} ->
          result = %State{state | connect: connect}
          {:noreply, reset_keep_alive(result)}

        %Connack{session_present: false} ->
          # delete inflight state ?
          if not Enum.empty?(state.subscriptions), do: send(self(), :subscribe)
          result = %State{state | connect: connect}
          {:noreply, reset_keep_alive(result)}
      end
    else
      %Connack{status: {:refused, reason}} ->
        {:stop, {:connection_failed, reason}}

      {:error, {:protocol_violation, violation}} ->
        Logger.error("Protocol violation: #{inspect(violation)}")
        {:stop, :protocol_violation}
    end
  end
end
