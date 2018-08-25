defmodule Tortoise.Connection do
  @moduledoc """
  Establish a connection to a MQTT broker.

  Todo.
  """

  use GenServer

  require Logger

  defstruct [:client_id, :connect, :server, :status, :backoff, :subscriptions, :keep_alive, :opts]
  alias __MODULE__, as: State

  @type client_id() :: binary() | atom()

  alias Tortoise.{Transport, Connection, Package, Events}
  alias Tortoise.Connection.{Inflight, Controller, Receiver, Backoff}
  alias Tortoise.Package.{Connect, Connack}

  @doc """
  Start a connection process and link it to the current process.

  Read the documentation on `child_spec/1` if you want... (todo!)

  """
  @spec start_link(connection_options, GenServer.options()) :: GenServer.on_start()
        when connection_option:
               {:client_id, String.t() | atom()}
               | {:user_name, String.t()}
               | {:password, String.t()}
               | {:keep_alive, pos_integer()}
               | {:will, Tortoise.Package.Publish.t()}
               | {:subscriptions, [{String.t(), 0..2}] | Tortoise.Package.Subscribe.t()}
               | {:handler, {atom(), term()}},
             connection_options: [connection_option]
  def start_link(connection_opts, opts \\ []) do
    client_id = Keyword.fetch!(connection_opts, :client_id)
    server = connection_opts |> Keyword.fetch!(:server) |> Transport.new()

    connect = %Package.Connect{
      client_id: client_id,
      user_name: Keyword.get(connection_opts, :user_name),
      password: Keyword.get(connection_opts, :password),
      keep_alive: Keyword.get(connection_opts, :keep_alive, 60),
      will: Keyword.get(connection_opts, :will),
      # if we re-spawn from here it means our state is gone
      clean_session: true
    }

    backoff = Keyword.get(connection_opts, :backoff, [])

    # This allow us to either pass in a list of topics, or a
    # subscription struct. Passing in a subscription struct is helpful
    # in tests.
    subscriptions =
      case Keyword.get(connection_opts, :subscriptions, []) do
        topics when is_list(topics) ->
          Enum.into(topics, %Package.Subscribe{})

        %Package.Subscribe{} = subscribe ->
          subscribe
      end

    # @todo, validate that the handler is valid
    connection_opts = Keyword.take(connection_opts, [:client_id, :handler])
    initial = {server, connect, backoff, subscriptions, connection_opts}
    opts = Keyword.merge(opts, name: via_name(client_id))
    GenServer.start_link(__MODULE__, initial, opts)
  end

  @doc false
  def via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :transient),
      type: :worker
    }
  end

  def disconnect(client_id) do
    GenServer.call(via_name(client_id), :disconnect)
  end

  @doc """
  Return the list of subscribed topics.

  Given the `client_id` of a running connection return its current
  subscriptions. This is helpful in a debugging situation.
  """
  @spec subscriptions(client_id()) :: Tortoise.Package.Subscribe.t()
  def subscriptions(client_id) do
    GenServer.call(via_name(client_id), :subscriptions)
  end

  @doc false
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

  @doc false
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

  @doc false
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

  @doc false
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

  @doc false
  @spec connection(client_id(), [opts]) ::
          {:ok, {module(), term()}} | {:error, :unknown_connection} | {:error, :timeout}
        when opts: {:timeout, non_neg_integer()} | {:active, boolean()}
  def connection(client_id, opts \\ [active: false]) do
    active = Keyword.get(opts, :active, false)

    case Tortoise.Registry.meta(via_name(client_id)) do
      {:ok, {_transport, _socket} = connection} ->
        if active, do: Events.register(client_id, :connection)
        {:ok, connection}

      {:ok, :connecting} ->
        timeout = Keyword.get(opts, :timeout, :infinity)
        {:ok, _} = Events.register(client_id, :connection)

        receive do
          {{Tortoise, ^client_id}, :connection, {transport, socket}} ->
            unless active, do: Events.unregister(client_id, :connection)
            {:ok, {transport, socket}}
        after
          timeout ->
            {:error, :timeout}
        end

      :error ->
        {:error, :unknown_connection}
    end
  end

  # Callbacks
  @impl true
  def init(
        {transport, %Connect{client_id: client_id} = connect, backoff_opts, subscriptions, opts}
      ) do
    state = %State{
      client_id: client_id,
      server: transport,
      connect: connect,
      backoff: Backoff.new(backoff_opts),
      subscriptions: subscriptions,
      opts: opts,
      status: :down
    }

    Tortoise.Registry.put_meta(via_name(client_id), :connecting)
    Tortoise.Events.register(client_id, :status)

    # eventually, switch to handle_continue
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ok = Tortoise.Registry.delete_meta(via_name(state.connect.client_id))
    :ok = Events.dispatch(state.client_id, :status, :terminated)
    :ok
  end

  @impl true
  def handle_info(:connect, state) do
    # make sure we will not fall for a keep alive timeout while we reconnect
    state = cancel_keep_alive(state)

    with {%Connack{status: :accepted} = connack, socket} <-
           do_connect(state.server, state.connect),
         {:ok, state} = init_connection(socket, state) do
      # we are connected; reset backoff state, etc
      state =
        %State{state | backoff: Backoff.reset(state.backoff)}
        |> update_connection_status(:up)
        |> reset_keep_alive()

      case connack do
        %Connack{session_present: true} ->
          {:noreply, state}

        %Connack{session_present: false} ->
          :ok = Inflight.reset(state.client_id)
          unless Enum.empty?(state.subscriptions), do: send(self(), :subscribe)
          {:noreply, state}
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
        Events.dispatch(state.connect.client_id, :ping_response, round_trip_time)
        state = reset_keep_alive(state)
        {:noreply, state}

      {:error, :timeout} ->
        {:stop, :ping_timeout, state}
    end
  end

  # dropping connection
  def handle_info({transport, _socket}, state) when transport in [:tcp_closed, :ssl_closed] do
    Logger.error("Socket closed before we handed it to the receiver")
    # communicate that we are down
    :ok = Events.dispatch(state.client_id, :status, :down)
    {:noreply, state}
  end

  # react to connection status change events
  def handle_info(
        {{Tortoise, client_id}, :status, status},
        %{client_id: client_id, status: current} = state
      ) do
    case status do
      ^current ->
        {:noreply, state}

      :up ->
        {:noreply, %State{state | status: status}}

      :down ->
        send(self(), :connect)
        {:noreply, %State{state | status: status}}
    end
  end

  @impl true
  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  def handle_call(:disconnect, from, state) do
    :ok = Events.dispatch(state.client_id, :status, :terminating)
    :ok = Inflight.drain(state.client_id)
    :ok = GenServer.reply(from, :ok)
    {:stop, :shutdown, state}
  end

  @impl true
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

  defp cancel_keep_alive(%State{keep_alive: nil} = state) do
    state
  end

  defp cancel_keep_alive(%State{keep_alive: keep_alive_ref} = state) do
    _ = Process.cancel_timer(keep_alive_ref)
    %State{state | keep_alive: nil}
  end

  # dispatch connection status if the connection status change
  defp update_connection_status(%State{status: same} = state, same) do
    state
  end

  defp update_connection_status(%State{} = state, status) do
    :ok = Events.dispatch(state.connect.client_id, :status, status)
    %State{state | status: status}
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

      {:error, :closed} ->
        {:error, :server_closed_connection}
    end
  end

  defp init_connection(socket, %State{opts: opts, server: transport, connect: connect} = state) do
    connection = {transport.type, socket}
    :ok = start_connection_supervisor(opts)
    :ok = Receiver.handle_socket(connect.client_id, connection)
    :ok = Tortoise.Registry.put_meta(via_name(connect.client_id), connection)
    :ok = Events.dispatch(connect.client_id, :connection, connection)

    # set clean session to false for future reconnect attempts
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

  defp categorize_error({:connection_refused, _host, _port}) do
    :connectivity
  end

  defp categorize_error(:server_closed_connection) do
    :connectivity
  end

  defp categorize_error(_other) do
    :other
  end
end
