defmodule Tortoise.Connection do
  @moduledoc false
  use GenServer

  require Logger

  defstruct [:connect, :server, :backoff, :subscriptions, :keep_alive, :opts]
  alias __MODULE__, as: State

  @type client_id() :: binary() | atom()

  alias Tortoise.{Transport, Connection, Package}
  alias Tortoise.Connection.{Inflight, Controller, Receiver, Transmitter, Backoff}
  alias Tortoise.Package.{Connect, Connack}

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    server = opts |> Keyword.fetch!(:server) |> Transport.new()

    connect = %Package.Connect{
      client_id: client_id,
      user_name: Keyword.get(opts, :user_name),
      password: Keyword.get(opts, :password),
      keep_alive: Keyword.get(opts, :keep_alive, 60),
      will: Keyword.get(opts, :last_will),
      # if we re-spawn from here it means our state is gone
      clean_session: true
    }

    backoff = Keyword.get(opts, :backoff, [])

    subscriptions =
      case Keyword.get(opts, :subscriptions, []) do
        topics when is_list(topics) ->
          Enum.into(topics, %Package.Subscribe{})

        %Package.Subscribe{} = subscribe ->
          subscribe
      end

    # @todo, validate that the handler is valid
    opts = Keyword.take(opts, [:client_id, :handler])
    initial = {server, connect, backoff, subscriptions, opts}
    GenServer.start_link(__MODULE__, initial, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
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
    caller = {_, ref} = {self(), make_ref()}
    {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)
    subscribe = Enum.into(topics, %Package.Subscribe{identifier: identifier})
    GenServer.cast(via_name(client_id), {:subscribe, caller, subscribe, opts})
    {:ok, ref}
  end

  def subscribe(client_id, {_, n} = topic, opts) when is_number(n) do
    subscribe(client_id, [topic], opts)
  end

  def subscribe(client_id, topic, opts) when is_binary(topic) do
    case Keyword.pop_first(opts, :qos) do
      {nil, _opts} ->
        throw("Please specify a quality of service for the subscription")

      {qos, opts} when qos in 0..2 ->
        subscribe(client_id, [{topic, qos}], opts)
    end
  end

  def subscribe_sync(client_id, topics, opts \\ [])

  def subscribe_sync(client_id, [{_, n} | _] = topics, opts) when is_number(n) do
    timeout = Keyword.get(opts, :timeout, 5000)
    {:ok, ref} = subscribe(client_id, topics, opts)

    receive do
      {{Tortoise, ^client_id}, ^ref, result} -> result
    after
      timeout ->
        {:error, :timeout}
    end
  end

  def subscribe_sync(client_id, {_, n} = topic, opts) when is_number(n) do
    subscribe_sync(client_id, [topic], opts)
  end

  def subscribe_sync(client_id, topic, opts) when is_binary(topic) do
    case Keyword.pop_first(opts, :qos) do
      {nil, _opts} ->
        throw("Please specify a quality of service for the subscription")

      {qos, opts} ->
        subscribe_sync(client_id, [{topic, qos}], opts)
    end
  end

  def unsubscribe(client_id, topics, opts \\ [])

  def unsubscribe(client_id, [topic | _] = topics, opts) when is_binary(topic) do
    caller = {_, ref} = {self(), make_ref()}
    {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)
    unsubscribe = %Package.Unsubscribe{identifier: identifier, topics: topics}
    GenServer.cast(via_name(client_id), {:unsubscribe, caller, unsubscribe, opts})
    {:ok, ref}
  end

  def unsubscribe(client_id, topic, opts) when is_binary(topic) do
    unsubscribe(client_id, [topic], opts)
  end

  def unsubscribe_sync(client_id, topics, opts \\ [])

  def unsubscribe_sync(client_id, topics, opts) when is_list(topics) do
    timeout = Keyword.get(opts, :timeout, 5000)
    {:ok, ref} = unsubscribe(client_id, topics, opts)

    receive do
      {{Tortoise, ^client_id}, ^ref, result} -> result
    after
      timeout ->
        {:error, :timeout}
    end
  end

  def unsubscribe_sync(client_id, topic, opts) when is_binary(topic) do
    unsubscribe_sync(client_id, [topic], opts)
  end

  def subscriptions(client_id) do
    GenServer.call(via_name(client_id), :subscriptions)
  end

  @doc false
  @spec renew(client_id()) :: :ok
  def renew(client_id) do
    case GenServer.whereis(via_name(client_id)) do
      pid when is_pid(pid) ->
        send(pid, :connect)

      nil ->
        {:error, :unknown_connection}
    end
  end

  # Callbacks
  def init({transport, %Connect{} = connect, backoff_opts, subscriptions, opts}) do
    state = %State{
      server: transport,
      connect: connect,
      backoff: Backoff.new(backoff_opts),
      subscriptions: subscriptions,
      opts: opts
    }

    # eventually, switch to handle_continue
    send(self(), :connect)
    {:ok, state}
  end

  def handle_info(:connect, state) do
    :ok = Controller.update_connection_status(state.connect.client_id, :down)

    with {%Connack{status: :accepted} = connack, socket} <-
           do_connect(state.server, state.connect),
         {:ok, state} = init_connection(socket, state) do
      # we are connected; reset backoff state
      state = %State{state | backoff: Backoff.reset(state.backoff)}

      case connack do
        %Connack{session_present: true} ->
          {:noreply, reset_keep_alive(state)}

        %Connack{session_present: false} ->
          # delete inflight state ?
          if not Enum.empty?(state.subscriptions), do: send(self(), :subscribe)
          {:noreply, reset_keep_alive(state)}
      end
    else
      %Connack{status: {:refused, reason}} ->
        {:stop, {:connection_failed, reason}, state}

      {:error, reason} ->
        {timeout, state} = Map.get_and_update(state, :backoff, &Backoff.next/1)

        case categorize_error(reason) do
          :connectivity ->
            Process.send_after(self(), :connect, timeout)
            {:noreply, state}

          :other ->
            {:stop, reason, state}
        end
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
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  def handle_cast({:subscribe, {caller_pid, ref}, subscribe, opts}, state) do
    client_id = state.connect.client_id
    timeout = Keyword.get(opts, :timeout, 5000)

    case Inflight.track_sync(client_id, {:outgoing, subscribe}, timeout) do
      {:error, :timeout} = error ->
        send(caller_pid, {{Tortoise, client_id}, ref, error})
        {:noreply, state}

      result ->
        case handle_suback_result(result, state) do
          {:ok, updated_state} ->
            send(caller_pid, {{Tortoise, client_id}, ref, :ok})
            {:noreply, updated_state}

          {:error, reasons} ->
            error = {:unable_to_subscribe, reasons}
            send(caller_pid, {{Tortoise, client_id}, ref, {:error, reasons}})
            {:stop, error, state}
        end
    end
  end

  def handle_cast({:unsubscribe, {caller_pid, ref}, unsubscribe, opts}, state) do
    client_id = state.connect.client_id
    timeout = Keyword.get(opts, :timeout, 5000)

    case Inflight.track_sync(client_id, {:outgoing, unsubscribe}, timeout) do
      {:error, :timeout} = error ->
        send(caller_pid, {{Tortoise, client_id}, ref, error})
        {:noreply, state}

      unsubbed ->
        topics = Keyword.drop(state.subscriptions.topics, unsubbed)
        subscriptions = %Package.Subscribe{state.subscriptions | topics: topics}
        send(caller_pid, {{Tortoise, client_id}, ref, :ok})
        {:noreply, %State{state | subscriptions: subscriptions}}
    end
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
    %Transport{type: transport, host: host, port: port, opts: opts} = server

    with {:ok, socket} <- transport.connect(host, port, opts, 10000),
         :ok = transport.send(socket, Package.encode(connect)),
         {:ok, packet} <- transport.recv(socket, 4, 5000) do
      try do
        case Package.decode(packet) do
          %Connack{status: :accepted} = connack ->
            {connack, socket}

          %Connack{status: {:refused, _reason}} = connack ->
            connack
        end
      catch
        :error, {:badmatch, _unexpected} ->
          violation = %{expected: Connect, got: packet}
          {:error, {:protocol_violation, violation}}
      end
    else
      {:error, :econnrefused} ->
        {:error, {:connection_refused, host, port}}

      {:error, :nxdomain} ->
        {:error, {:nxdomain, host, port}}

      {:error, {:options, {:cacertfile, []}}} ->
        {:error, :no_cacartfile_specified}
    end
  end

  defp init_connection(socket, %State{opts: opts, server: transport, connect: connect} = state) do
    :ok = start_connection_supervisor(opts)
    :ok = Receiver.handle_socket(connect.client_id, {transport.type, socket})
    :ok = Controller.update_connection_status(connect.client_id, :up)
    connect = %Connect{connect | clean_session: false}
    {:ok, %State{state | connect: connect}}
  end

  defp start_connection_supervisor(opts) do
    case Connection.Supervisor.start_link(opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp categorize_error({:nxdomain, _host, _port}) do
    :connectivity
  end

  defp categorize_error(_other) do
    :other
  end
end
