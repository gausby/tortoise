defmodule Tortoise.Connection do
  @moduledoc """
  Establish a connection to a MQTT broker.

  Todo.
  """

  use GenStateMachine

  require Logger

  defstruct client_id: nil,
            connect: nil,
            server: nil,
            backoff: nil,
            subscriptions: nil,
            opts: nil,
            pending_refs: %{},
            connection: nil,
            ping: {:idle, []},
            handler: nil,
            receiver: nil

  alias __MODULE__, as: State

  alias Tortoise.{Handler, Transport, Package, Events}
  alias Tortoise.Connection.{Receiver, Inflight, Backoff}
  alias Tortoise.Package.Connect

  @doc """
  Start a connection process and link it to the current process.

  Read the documentation on `child_spec/1` if you want... (todo!)

  """
  @spec start_link(options, GenServer.options()) :: GenServer.on_start()
        when option:
               {:client_id, Tortoise.client_id()}
               | {:user_name, String.t()}
               | {:password, String.t()}
               | {:keep_alive, non_neg_integer()}
               | {:will, Tortoise.Package.Publish.t()}
               | {:subscriptions,
                  [{Tortoise.topic_filter(), Tortoise.qos()}] | Tortoise.Package.Subscribe.t()}
               | {:handler, {atom(), term()}},
             options: [option]
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
      clean_start: true
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
    handler =
      connection_opts
      |> Keyword.get(:handler, %Handler{module: Handler.Default, initial_args: []})
      |> Handler.new()

    connection_opts = [
      {:transport, server} | Keyword.take(connection_opts, [:client_id])
    ]

    initial = {server, connect, backoff, subscriptions, handler, connection_opts}
    opts = Keyword.merge(opts, name: via_name(client_id))
    GenStateMachine.start_link(__MODULE__, initial, opts)
  end

  @doc false
  @spec via_name(Tortoise.client_id()) ::
          pid() | {:via, Registry, {Tortoise.Registry, {atom(), Tortoise.client_id()}}}
  def via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  @spec child_spec(Keyword.t()) :: %{
          id: term(),
          start: {__MODULE__, :start_link, [Keyword.t()]},
          restart: :transient | :permanent | :temporary,
          type: :worker
        }
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :transient),
      type: :worker
    }
  end

  @doc """
  Close the connection to the broker.

  Given the `client_id` of a running connection it will cancel the
  inflight messages and send the proper disconnect message to the
  broker. The session will get terminated on the server.
  """
  @spec disconnect(Tortoise.client_id()) :: :ok
  def disconnect(client_id) do
    GenStateMachine.call(via_name(client_id), :disconnect)
  end

  @doc """
  Return the list of subscribed topics.

  Given the `client_id` of a running connection return its current
  subscriptions. This is helpful in a debugging situation.
  """
  @spec subscriptions(Tortoise.client_id()) :: Tortoise.Package.Subscribe.t()
  def subscriptions(client_id) do
    GenStateMachine.call(via_name(client_id), :subscriptions)
  end

  @doc """
  Subscribe to one or more topics using topic filters on `client_id`

  The topic filter should be a 2-tuple, `{topic_filter, qos}`, where
  the `topic_filter` is a valid MQTT topic filter, and `qos` an
  integer value 0 through 2.

  Multiple topics can be given as a list.

  The subscribe function is asynchronous, so it will return `{:ok,
  ref}`. Eventually a response will get delivered to the process
  mailbox, tagged with the reference stored in `ref`. It will take the
  form of:

      {{Tortoise, ^client_id}, ^ref, ^result}

  Where the `result` can be one of `:ok`, or `{:error, reason}`.

  Read the documentation for `Tortoise.Connection.subscribe_sync/3`
  for a blocking version of this call.
  """
  @spec subscribe(Tortoise.client_id(), topic | topics, [options]) :: {:ok, reference()}
        when topics: [topic],
             topic: {Tortoise.topic_filter(), Tortoise.qos()},
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
  def subscribe(client_id, topics, opts \\ [])

  def subscribe(client_id, [{_, n} | _] = topics, opts) when is_number(n) do
    caller = {_, ref} = {self(), make_ref()}
    {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)
    subscribe = Enum.into(topics, %Package.Subscribe{identifier: identifier})
    GenStateMachine.cast(via_name(client_id), {:subscribe, caller, subscribe, opts})
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

  @doc """
  Subscribe to topics and block until the server acknowledges.

  This is a synchronous version of the
  `Tortoise.Connection.subscribe/3`. In fact it calls into
  `Tortoise.Connection.subscribe/3` but will handle the selective
  receive loop, making it much easier to work with. Also, this
  function can be used to block a process that cannot continue before
  it has a subscription to the given topics.

  See `Tortoise.Connection.subscribe/3` for configuration options.
  """
  @spec subscribe_sync(Tortoise.client_id(), topic | topics, [options]) ::
          :ok | {:error, :timeout}
        when topics: [topic],
             topic: {Tortoise.topic_filter(), Tortoise.qos()},
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
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

  @doc """
  Unsubscribe from one of more topic filters. The topic filters are
  given as strings. Multiple topic filters can be given at once by
  passing in a list of strings.

      Tortoise.Connection.unsubscribe(client_id, ["foo/bar", "quux"])

  This operation is asynchronous. When the operation is done a message
  will be received in mailbox of the originating process.
  """
  @spec unsubscribe(Tortoise.client_id(), topic | topics, [options]) :: {:ok, reference()}
        when topics: [topic],
             topic: Tortoise.topic_filter(),
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
  def unsubscribe(client_id, topics, opts \\ [])

  def unsubscribe(client_id, [topic | _] = topics, opts) when is_binary(topic) do
    caller = {_, ref} = {self(), make_ref()}
    {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)
    unsubscribe = %Package.Unsubscribe{identifier: identifier, topics: topics}
    GenStateMachine.cast(via_name(client_id), {:unsubscribe, caller, unsubscribe, opts})
    {:ok, ref}
  end

  def unsubscribe(client_id, topic, opts) when is_binary(topic) do
    unsubscribe(client_id, [topic], opts)
  end

  @doc """
  Unsubscribe from topics and block until the server acknowledges.

  This is a synchronous version of
  `Tortoise.Connection.unsubscribe/3`. It will block until the server
  has send the acknowledge message.

  See `Tortoise.Connection.unsubscribe/3` for configuration options.
  """
  @spec unsubscribe_sync(Tortoise.client_id(), topic | topics, [options]) ::
          :ok | {:error, :timeout}
        when topics: [topic],
             topic: Tortoise.topic_filter(),
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
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

  @doc """
  Ping the broker.

  When the round-trip is complete a message with the time taken in
  milliseconds will be send to the process that invoked the ping
  command.

  The connection will automatically ping the broker at the interval
  specified in the connection configuration, so there is no need to
  setup a reoccurring ping. This ping function is exposed for
  debugging purposes. If ping latency over time is desired it is
  better to listen on `:ping_response` using the `Tortoise.Events`
  PubSub.
  """
  @spec ping(Tortoise.client_id()) :: {:ok, reference()}
  def ping(client_id) do
    ref = make_ref()
    :ok = GenStateMachine.cast(via_name(client_id), {:ping, {self(), ref}})
    {:ok, ref}
  end

  @doc """
  Ping the server and await the ping latency reply.

  Takes a `client_id` and an optional `timeout`.

  Like `ping/1` but will block the caller process until a response is
  received from the server. The response will contain the ping latency
  in milliseconds.  The `timeout` defaults to `:infinity`, so it is
  advisable to specify a reasonable time one is willing to wait for a
  response.
  """
  @spec ping_sync(Tortoise.client_id(), timeout()) :: {:ok, reference()} | {:error, :timeout}
  def ping_sync(client_id, timeout \\ :infinity) do
    {:ok, ref} = ping(client_id)

    receive do
      {{Tortoise, ^client_id}, {Package.Pingreq, ^ref}, round_trip_time} ->
        {:ok, round_trip_time}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc false
  @spec connection(Tortoise.client_id(), [opts]) ::
          {:ok, {module(), term()}} | {:error, :unknown_connection} | {:error, :timeout}
        when opts: {:timeout, timeout()} | {:active, boolean()}
  def connection(client_id, opts \\ [active: false]) do
    # register a connection subscription in the case we are currently
    # in the connect phase; this solves a possible race condition
    # where the connection is requested while the status is
    # connecting, but will reach the receive block after the message
    # has been dispatched from the pubsub; previously we registered
    # for the connection message in this window.
    {:ok, _} = Events.register(client_id, :connection)

    case Tortoise.Registry.meta(via_name(client_id)) do
      {:ok, {_transport, _socket} = connection} ->
        {:ok, connection}

      {:ok, :connecting} ->
        timeout = Keyword.get(opts, :timeout, :infinity)

        receive do
          {{Tortoise, ^client_id}, :connection, {transport, socket}} ->
            {:ok, {transport, socket}}
        after
          timeout ->
            {:error, :timeout}
        end

      :error ->
        {:error, :unknown_connection}
    end
  after
    # if the connection subscription is non-active we should remove it
    # from the registry, so the process will not receive connection
    # messages when the connection is reestablished.
    active? = Keyword.get(opts, :active, false)
    unless active?, do: Events.unregister(client_id, :connection)
  end

  # Callbacks
  @impl true
  def init({transport, connect, backoff_opts, subscriptions, handler, opts}) do
    data = %State{
      client_id: connect.client_id,
      server: transport,
      connect: connect,
      backoff: Backoff.new(backoff_opts),
      subscriptions: subscriptions,
      opts: opts,
      handler: handler
    }

    case Handler.execute_init(handler) do
      {:ok, %Handler{} = updated_handler} ->
        next_events = [{:next_event, :internal, :connect}]
        updated_data = %State{data | handler: updated_handler}
        {:ok, :connecting, updated_data, next_events}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, _state, %State{handler: handler}) do
    _ignored = Handler.execute_terminate(handler, reason)
  end

  @impl true
  def handle_event(:info, {:incoming, package}, _, _data) when is_binary(package) do
    next_actions = [{:next_event, :internal, {:received, Package.decode(package)}}]
    {:keep_state_and_data, next_actions}
  end

  # connection acknowledgement
  def handle_event(
        :internal,
        {:received, %Package.Connack{reason: :success} = connack},
        :connecting,
        %State{
          client_id: client_id,
          server: %Transport{type: transport},
          connection: {transport, _},
          connect: %Package.Connect{keep_alive: keep_alive}
        } = data
      ) do
    :ok = Tortoise.Registry.put_meta(via_name(client_id), data.connection)
    :ok = Events.dispatch(client_id, :connection, data.connection)
    :ok = Events.dispatch(client_id, :status, :connected)
    data = %State{data | backoff: Backoff.reset(data.backoff)}

    case connack do
      %Package.Connack{session_present: true} ->
        next_actions = [
          {:state_timeout, keep_alive * 1000, :keep_alive},
          {:next_event, :internal, {:execute_handler, {:connection, :up}}}
        ]

        {:next_state, :connected, data, next_actions}

      %Package.Connack{session_present: false} ->
        caller = {self(), make_ref()}

        next_actions = [
          {:state_timeout, keep_alive * 1000, :keep_alive},
          {:next_event, :internal, {:execute_handler, {:connection, :up}}},
          {:next_event, :cast, {:subscribe, caller, data.subscriptions, []}}
        ]

        {:next_state, :connected, data, next_actions}
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Connack{reason: {:refused, reason}}},
        :connecting,
        %State{} = data
      ) do
    {:stop, {:connection_failed, reason}, data}
  end

  def handle_event(
        :internal,
        {:received, package},
        :connecting,
        %State{} = data
      ) do
    reason = %{expected: [Package.Connack, Package.Auth], got: package}
    {:stop, {:protocol_violation, reason}, data}
  end

  # publish packages ===================================================
  def handle_event(
        :internal,
        {:received, %Package.Publish{qos: 0, dup: false} = publish},
        _,
        %State{handler: handler} = data
      ) do
    case Handler.execute_handle_publish(handler, publish) do
      {:ok, %Handler{} = updated_handler} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

        # handle stop
    end
  end

  # incoming publish QoS>0 ---------------------------------------------
  def handle_event(
        :internal,
        {:received, %Package.Publish{qos: qos} = publish},
        _,
        %State{client_id: client_id}
      )
      when qos in 1..2 do
    :ok = Inflight.track(client_id, {:incoming, publish})
    :keep_state_and_data
  end

  # outgoing publish QoS=1 ---------------------------------------------
  def handle_event(
        :internal,
        {:received, %Package.Puback{} = puback},
        _,
        %State{client_id: client_id, handler: handler} = data
      ) do
    :ok = Inflight.update(client_id, {:received, puback})

    case Handler.execute_handle_puback(handler, puback) do
      {:ok, %Handler{} = updated_handler} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

      {:error, reason} ->
        # todo
        {:stop, reason, data}
    end
  end

  # incoming publish QoS=2 ---------------------------------------------
  def handle_event(
        :internal,
        {:received, %Package.Pubrel{identifier: id} = pubrel},
        _,
        %State{client_id: client_id, handler: handler} = data
      ) do
    :ok = Inflight.update(client_id, {:received, pubrel})

    case Handler.execute_handle_pubrel(handler, pubrel) do
      {:ok, %Handler{} = updated_handler} ->
        # dispatch a pubcomp
        pubcomp = %Package.Pubcomp{identifier: id}
        :ok = Inflight.update(client_id, {:dispatch, pubcomp})
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

      {:error, reason} ->
        # todo
        {:stop, reason, data}
    end
  end

  # an incoming publish with QoS>0 will get parked in the inflight
  # manager process, which will onward it to the controller, making
  # sure we will only dispatch it once to the publish-handler.
  def handle_event(
        :info,
        {{Inflight, client_id}, %Package.Publish{identifier: id, qos: 1} = publish},
        _,
        %State{client_id: client_id, handler: handler} = data
      ) do
    case Handler.execute_handle_publish(handler, publish) do
      {:ok, %Handler{} = updated_handler} ->
        # respond with a puback
        puback = %Package.Puback{identifier: id}
        :ok = Inflight.update(client_id, {:dispatch, puback})
        # - - -
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

        # handle stop
    end
  end

  def handle_event(
        :info,
        {{Inflight, client_id}, %Package.Publish{identifier: id, qos: 2} = publish},
        _,
        %State{client_id: client_id, handler: handler} = data
      ) do
    case Handler.execute_handle_publish(handler, publish) do
      {:ok, %Handler{} = updated_handler} ->
        # respond with pubrec
        pubrec = %Package.Pubrec{identifier: id}
        :ok = Inflight.update(client_id, {:dispatch, pubrec})
        # - - -
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}
    end
  end

  # outgoing publish QoS=2 ---------------------------------------------
  def handle_event(
        :internal,
        {:received, %Package.Pubrec{identifier: id} = pubrec},
        _,
        %State{client_id: client_id, handler: handler} = data
      ) do
    :ok = Inflight.update(client_id, {:received, pubrec})

    case Handler.execute_handle_pubrec(handler, pubrec) do
      {:ok, %Handler{} = updated_handler} ->
        pubrel = %Package.Pubrel{identifier: id}
        :ok = Inflight.update(client_id, {:dispatch, pubrel})

        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

      {:error, reason} ->
        # todo
        {:stop, reason, data}
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Pubcomp{} = pubcomp},
        :connected,
        %State{client_id: client_id, handler: handler} = data
      ) do
    :ok = Inflight.update(client_id, {:received, pubcomp})

    case Handler.execute_handle_pubcomp(handler, pubcomp) do
      {:ok, %Handler{} = updated_handler} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

      {:error, reason} ->
        # todo
        {:stop, reason, data}
    end
  end

  # subscription logic
  def handle_event(
        :cast,
        {:subscribe, caller, subscribe, _opts},
        :connected,
        %State{client_id: client_id} = data
      ) do
    unless Enum.empty?(subscribe) do
      {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})
      pending = Map.put_new(data.pending_refs, ref, caller)

      {:keep_state, %State{data | pending_refs: pending}}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:cast, {:subscribe, _, _, _}, _state_name, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event(
        :internal,
        {:received, %Package.Suback{} = suback},
        :connected,
        data
      ) do
    :ok = Inflight.update(data.client_id, {:received, suback})
    :keep_state_and_data
  end

  def handle_event(
        :info,
        {{Tortoise, client_id}, {Package.Subscribe, ref}, result},
        _current_state,
        %State{client_id: client_id, pending_refs: %{} = pending} = data
      ) do
    case Map.pop(pending, ref) do
      {{pid, msg_ref}, updated_pending} when is_pid(pid) and is_reference(msg_ref) ->
        unless pid == self(), do: send(pid, {{Tortoise, client_id}, msg_ref, :ok})
        subscriptions = Enum.into(result[:ok] ++ result[:warn], data.subscriptions)
        updated_data = %State{data | subscriptions: subscriptions, pending_refs: updated_pending}
        next_actions = [{:next_event, :internal, {:execute_handler, {:subscribe, result}}}]
        {:keep_state, updated_data, next_actions}
    end
  end

  def handle_event(:cast, {:unsubscribe, caller, unsubscribe, opts}, :connected, data) do
    client_id = data.client_id
    _timeout = Keyword.get(opts, :timeout, 5000)

    {:ok, ref} = Inflight.track(client_id, {:outgoing, unsubscribe})
    pending = Map.put_new(data.pending_refs, ref, caller)

    {:keep_state, %State{data | pending_refs: pending}}
  end

  def handle_event(
        :internal,
        {:received, %Package.Unsuback{results: [_ | _]} = unsuback},
        :connected,
        data
      ) do
    :ok = Inflight.update(data.client_id, {:received, unsuback})
    :keep_state_and_data
  end

  # todo; handle the unsuback error cases !
  def handle_event(
        :info,
        {{Tortoise, client_id}, {Package.Unsubscribe, ref}, unsubbed},
        _current_state,
        %State{client_id: client_id, pending_refs: %{} = pending} = data
      ) do
    case Map.pop(pending, ref) do
      {{pid, msg_ref}, updated_pending} when is_pid(pid) and is_reference(msg_ref) ->
        topics = Keyword.drop(data.subscriptions.topics, unsubbed)
        subscriptions = %Package.Subscribe{data.subscriptions | topics: topics}
        unless pid == self(), do: send(pid, {{Tortoise, client_id}, msg_ref, :ok})
        updated_data = %State{data | pending_refs: updated_pending, subscriptions: subscriptions}
        next_actions = [{:next_event, :internal, {:execute_handler, {:unsubscribe, unsubbed}}}]
        {:keep_state, updated_data, next_actions}
    end
  end

  def handle_event({:call, from}, :subscriptions, _, %State{subscriptions: subscriptions}) do
    next_actions = [{:reply, from, subscriptions}]
    {:keep_state_and_data, next_actions}
  end

  # dispatch to user defined handler
  def handle_event(
        :internal,
        {:execute_handler, {:connection, status}},
        :connected,
        %State{handler: handler} = data
      ) do
    case Handler.execute_connection(handler, status) do
      {:ok, %Handler{} = updated_handler} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

        # handle stop
    end
  end

  def handle_event(
        :internal,
        {:execute_handler, {:subscribe, results}},
        _,
        %State{handler: handler} = data
      ) do
    case Handler.execute_subscribe(handler, results) do
      {:ok, %Handler{} = updated_handler} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

        # handle stop
    end
  end

  def handle_event(
        :internal,
        {:execute_handler, {:unsubscribe, result}},
        _current_state,
        %State{handler: handler} = data
      ) do
    case Handler.execute_unsubscribe(handler, result) do
      {:ok, %Handler{} = updated_handler} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data}

        # handle stop
    end
  end

  # connection logic ===================================================
  def handle_event(:internal, :connect, :connecting, %State{} = data) do
    :ok = Tortoise.Registry.put_meta(via_name(data.client_id), :connecting)
    :ok = start_connection_supervisor([{:parent, self()} | data.opts])

    case await_and_monitor_receiver(data) do
      {:ok, data} ->
        {timeout, updated_data} = Map.get_and_update(data, :backoff, &Backoff.next/1)
        next_actions = [{:state_timeout, timeout, :attempt_connection}]
        {:keep_state, updated_data, next_actions}
    end
  end

  def handle_event(
        :state_timeout,
        :attempt_connection,
        :connecting,
        %State{connect: connect} = data
      ) do
    with {:ok, {transport, socket}} <- Receiver.connect(data.client_id),
         :ok = transport.send(socket, Package.encode(connect)) do
      new_data = %State{
        data
        | connect: %Connect{connect | clean_start: false},
          connection: {transport, socket}
      }

      {:keep_state, new_data}
    else
      {:error, {:stop, reason}} ->
        {:stop, reason, data}

      {:error, {:retry, _reason}} ->
        next_actions = [{:next_event, :internal, :connect}]
        {:keep_state, data, next_actions}
    end
  end

  # disconnect protocol messages ---------------------------------------
  def handle_event(
        {:call, from},
        :disconnect,
        :connected,
        %State{client_id: client_id} = data
      ) do
    :ok = Events.dispatch(client_id, :status, :terminating)

    :ok = Inflight.drain(client_id)

    {:stop_and_reply, :shutdown, [{:reply, from, :ok}], data}
  end

  def handle_event(
        {:call, _from},
        :disconnect,
        _,
        %State{}
      ) do
    {:keep_state_and_data, [:postpone]}
  end

  # ping handling ------------------------------------------------------
  def handle_event(:cast, {:ping, caller}, :connected, %State{} = data) do
    case data.ping do
      {:idle, awaiting} ->
        # set the keep alive timeout to trigger instantly
        next_actions = [{:state_timeout, 0, :keep_alive}]
        {:keep_state, %State{data | ping: {:idle, [caller | awaiting]}}, next_actions}

      {{:pinging, start_time}, awaiting} ->
        {:keep_state, %State{data | ping: {{:pinging, start_time}, [caller | awaiting]}}}
    end
  end

  # not connected yet
  def handle_event(:cast, {:ping, {caller_pid, ref}}, _, %State{client_id: client_id}) do
    send(caller_pid, {{Tortoise, client_id}, {Package.Pingreq, ref}, :not_connected})
    :keep_state_and_data
  end

  def handle_event(
        :state_timeout,
        :keep_alive,
        :connected,
        %State{connection: {transport, socket}, ping: {:idle, awaiting}} = data
      ) do
    start_time = System.monotonic_time()

    :ok = transport.send(socket, Package.encode(%Package.Pingreq{}))

    {:keep_state, %State{data | ping: {{:pinging, start_time}, awaiting}}}
  end

  def handle_event(
        :internal,
        {:received, %Package.Pingresp{}},
        :connected,
        %State{
          client_id: client_id,
          ping: {{:pinging, start_time}, awaiting},
          connect: %Package.Connect{keep_alive: keep_alive}
        } = data
      ) do
    round_trip_time =
      (System.monotonic_time() - start_time)
      |> System.convert_time_unit(:native, :microsecond)

    :ok = Events.dispatch(client_id, :ping_response, round_trip_time)

    for {caller, ref} <- awaiting do
      send(caller, {{Tortoise, client_id}, {Package.Pingreq, ref}, round_trip_time})
    end

    next_actions = [{:state_timeout, keep_alive * 1000, :keep_alive}]

    {:keep_state, %State{data | ping: {:idle, []}}, next_actions}
  end

  # disconnect packages
  def handle_event(
        :internal,
        {:received, %Package.Disconnect{} = disconnect},
        _current_state,
        %State{handler: handler} = data
      ) do
    case Handler.execute_disconnect(handler, disconnect) do
      {:stop, reason, updated_handler} ->
        {:stop, reason, %State{data | handler: updated_handler}}
    end
  end

  # unexpected package
  def handle_event(
        :internal,
        {:received, package},
        _current_state,
        %State{} = data
      ) do
    {:stop, {:protocol_violation, {:unexpected_package, package}}, data}
  end

  def handle_event(
        :info,
        {:DOWN, receiver_ref, :process, receiver_pid, _reason},
        state,
        %State{receiver: {receiver_pid, receiver_ref}} = data
      )
      when state in [:connected, :connecting] do
    next_actions = [{:next_event, :internal, :connect}]
    updated_data = %State{data | receiver: nil}
    {:next_state, :connecting, updated_data, next_actions}
  end

  defp await_and_monitor_receiver(%State{client_id: client_id, receiver: nil} = data) do
    receive do
      {{Tortoise, ^client_id}, Receiver, {:ready, pid}} ->
        {:ok, %State{data | receiver: {pid, Process.monitor(pid)}}}
    after
      5000 ->
        {:error, :receiver_timeout}
    end
  end

  defp await_and_monitor_receiver(data) do
    {:ok, data}
  end

  defp start_connection_supervisor(opts) do
    case Tortoise.Connection.Supervisor.start_link(opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
