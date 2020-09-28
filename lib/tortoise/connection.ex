defmodule Tortoise.Connection do
  @moduledoc """
  Establish a connection to a MQTT broker.

  Todo.
  """

  use GenStateMachine

  require Logger

  defstruct session_ref: nil,
            client_id: nil,
            session: nil,
            connect: nil,
            server: nil,
            backoff: nil,
            opts: nil,
            pending_refs: %{},
            connection: nil,
            ping: {:idle, []},
            handler: nil,
            receiver: nil,
            info: nil

  alias __MODULE__, as: State

  alias Tortoise.{Handler, Transport, Package, Session}
  alias Tortoise.Connection.{Info, Receiver, Backoff}
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

    # @todo, validate that the handler is valid
    handler =
      connection_opts
      |> Keyword.get(:handler, %Handler{module: Handler.Default, initial_args: []})
      |> Handler.new()

    connection_opts = [
      {:transport, server} | Keyword.take(connection_opts, [:client_id])
    ]

    initial = %State{
      session_ref: make_ref(),
      client_id: connect.client_id,
      session: %Session{client_id: connect.client_id},
      server: server,
      connect: connect,
      backoff: Backoff.new(backoff),
      opts: connection_opts,
      handler: handler
    }

    GenStateMachine.start_link(__MODULE__, initial, opts)
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

  Given the `pid` of a running connection it will cancel the inflight
  messages and send the proper disconnect message to the broker. The
  session will get terminated on the server.
  """
  @spec disconnect(pid(), reason, properties) :: :ok
        when reason: Tortoise.Package.Disconnect.reason(),
             properties: [property],
             property:
               {:reason_string, String.t()}
               | {:server_reference, String.t()}
               | {:session_expiry_interval, 0..0xFFFFFFFF}
               | {:user_property, {String.t(), String.t()}}

  def disconnect(pid, reason \\ :normal_disconnection, properties \\ []) do
    disconnect = %Package.Disconnect{reason: reason, properties: properties}
    GenStateMachine.call(pid, {:disconnect, disconnect})
  end

  @doc """
  Return the list of subscribed topics.

  Given the `client_id` of a running connection return its current
  subscriptions. This is helpful in a debugging situation.
  """
  @spec subscriptions(pid()) :: Tortoise.Package.Subscribe.t()
  def subscriptions(pid) do
    GenStateMachine.call(pid, :subscriptions)
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
  @spec subscribe(pid(), topic | topics, [options]) :: {:ok, {Tortoise.client_id(), reference()}}
        when topics: [topic],
             topic: {Tortoise.topic_filter(), Tortoise.qos()},
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
  def subscribe(pid, topics, opts \\ [])

  def subscribe(pid, [{_, topic_opts} | _] = topics, opts) when is_list(topic_opts) do
    # todo, do something with timeout, or remove it
    {opts, properties} = Keyword.split(opts, [:identifier, :timeout])
    {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)

    subscribe =
      Enum.into(topics, %Package.Subscribe{
        identifier: identifier,
        properties: properties
      })

    GenStateMachine.call(pid, {:subscribe, subscribe, opts})
  end

  def subscribe(pid, {_, topic_opts} = topic, opts) when is_list(topic_opts) do
    subscribe(pid, [topic], opts)
  end

  def subscribe(pid, topic, opts) when is_binary(topic) do
    case Keyword.pop_first(opts, :qos) do
      {nil, _opts} ->
        throw("Please specify a quality of service for the subscription")

      {qos, opts} when qos in 0..2 ->
        subscribe(pid, [{topic, [qos: qos]}], opts)
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
  @spec subscribe_sync(pid(), topic | topics, [options]) ::
          :ok | {:error, :timeout}
        when topics: [topic],
             topic: {Tortoise.topic_filter(), Tortoise.qos()},
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
  def subscribe_sync(pid, topics, opts \\ [])

  def subscribe_sync(pid, [{_, topic_opts} | _] = topics, opts) when is_list(topic_opts) do
    case subscribe(pid, topics, opts) do
      {:ok, {client_id, ref}} ->
        timeout = Keyword.get(opts, :timeout, 5000)

        receive do
          {{Tortoise, ^client_id}, {Package.Suback, ^ref}, result} -> result
        after
          timeout ->
            {:error, :timeout}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def subscribe_sync(pid, {_, topic_opts} = topic, opts) when is_list(topic_opts) do
    subscribe_sync(pid, [topic], opts)
  end

  def subscribe_sync(pid, topic, opts) when is_binary(topic) do
    case Keyword.pop_first(opts, :qos) do
      {nil, _opts} ->
        throw("Please specify a quality of service for the subscription")

      {qos, opts} ->
        subscribe_sync(pid, [{topic, qos: qos}], opts)
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
  @spec unsubscribe(pid(), topic | topics, [options]) ::
          {:ok, {Tortoise.client_id(), reference()}}
        when topics: [topic],
             topic: Tortoise.topic_filter(),
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
  def unsubscribe(pid, topics, opts \\ [])

  def unsubscribe(pid, [topic | _] = topics, opts) when is_binary(topic) do
    {opts, properties} = Keyword.split(opts, [:identifier, :timeout])
    {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)

    unsubscribe = %Package.Unsubscribe{
      identifier: identifier,
      topics: topics,
      properties: properties
    }

    GenStateMachine.call(pid, {:unsubscribe, unsubscribe, opts})
  end

  def unsubscribe(pid, topic, opts) when is_binary(topic) do
    unsubscribe(pid, [topic], opts)
  end

  @doc """
  Unsubscribe from topics and block until the server acknowledges.

  This is a synchronous version of
  `Tortoise.Connection.unsubscribe/3`. It will block until the server
  has send the acknowledge message.

  See `Tortoise.Connection.unsubscribe/3` for configuration options.
  """
  @spec unsubscribe_sync(pid(), topic | topics, [options]) ::
          :ok | {:error, :timeout}
        when topics: [topic],
             topic: Tortoise.topic_filter(),
             options:
               {:timeout, timeout()}
               | {:identifier, Tortoise.package_identifier()}
  def unsubscribe_sync(pid, topics, opts \\ [])

  def unsubscribe_sync(pid, topics, opts) when is_list(topics) do
    timeout = Keyword.get(opts, :timeout, 5000)
    {:ok, {client_id, ref}} = unsubscribe(pid, topics, opts)

    receive do
      {{Tortoise, ^client_id}, {Package.Unsuback, ^ref}, result} ->
        result
    after
      timeout ->
        {:error, :timeout}
    end
  end

  def unsubscribe_sync(pid, topic, opts) when is_binary(topic) do
    unsubscribe_sync(pid, [topic], opts)
  end

  @doc """
  Publish a message, but go through the connection

  In most circumstances it would be preferable to go through the
  publish function on the Tortoise module instead.
  """
  def publish(pid, %Package.Publish{} = publish) do
    GenStateMachine.call(pid, {:publish, publish})
  end

  def publish_sync(pid, %Package.Publish{} = publish, timeout \\ :infinity) do
    {:ok, {client_id, ref}} = publish(pid, publish)

    receive do
      {{Tortoise, ^client_id}, {Package.Publish, ^ref}, result} ->
        result
    after
      timeout ->
        {:error, :timeout}
    end
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
  @spec ping(pid(), timeout()) :: {:ok, reference()}
  def ping(pid, timeout \\ :infinity) do
    GenStateMachine.call(pid, :ping, timeout)
  end

  @doc """
  Ping the server and await the ping latency reply.

  Takes a `pid` and an optional `timeout`.

  Like `ping/1` but will block the caller process until a response is
  received from the server. The response will contain the ping latency
  in milliseconds.  The `timeout` defaults to `:infinity`, so it is
  advisable to specify a reasonable time one is willing to wait for a
  response.
  """
  @spec ping_sync(pid(), timeout()) :: {:ok, reference()} | {:error, :timeout}
  def ping_sync(pid, timeout \\ :infinity) do
    case ping(pid, timeout) do
      {:ok, {client_id, ref}} ->
        receive do
          {{Tortoise, ^client_id}, {Package.Pingreq, ^ref}, round_trip_time} ->
            {:ok, round_trip_time}
        after
          timeout ->
            {:error, :timeout}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Get the info on the current connection configuration
  """
  def info(pid) do
    GenStateMachine.call(pid, :get_info)
  end

  @doc false
  @spec connection(pid(), [opts]) ::
          {:ok, {module(), term()}} | {:error, :unknown_connection} | {:error, :timeout}
        when opts: {:timeout, timeout()} | {:active, boolean()}
  def connection(pid, _opts \\ [active: false])

  def connection(name_or_pid, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    # TODO make it possible to subscribe to a connection using "active"!
    if GenServer.whereis(name_or_pid) |> Process.alive?() do
      GenStateMachine.call(name_or_pid, :get_connection, timeout)
    else
      {:error, :unknown_connection}
    end
  end

  # def connection(client_id, opts) do
  #   # register a connection subscription in the case we are currently
  #   # in the connect phase; this solves a possible race condition
  #   # where the connection is requested while the status is
  #   # connecting, but will reach the receive block after the message
  #   # has been dispatched from the pubsub; previously we registered
  #   # for the connection message in this window.
  #   {:ok, _} = Events.register(client_id, :connection)

  #   case Tortoise.Registry.meta(via_name(client_id)) do
  #     {:ok, {_transport, _socket} = connection} ->
  #       {:ok, connection}

  #     {:ok, :connecting} ->
  #       timeout = Keyword.get(opts, :timeout, :infinity)

  #       receive do
  #         {{Tortoise, ^client_id}, :connection, {transport, socket}} ->
  #           {:ok, {transport, socket}}
  #       after
  #         timeout ->
  #           {:error, :timeout}
  #       end

  #     :error ->
  #       {:error, :unknown_connection}
  #   end
  # after
  #   # if the connection subscription is non-active we should remove it
  #   # from the registry, so the process will not receive connection
  #   # messages when the connection is reestablished.
  #   active? = Keyword.get(opts, :active, false)
  #   unless active?, do: Events.unregister(client_id, :connection)
  # end

  # Callbacks
  @impl true
  def init(%State{} = state) do
    case Handler.execute_init(state.handler) do
      {:ok, %Handler{} = updated_handler} ->
        updated_state = %State{state | handler: updated_handler}
        # TODO, perhaps the supervision should get reconsidered
        :ok =
          start_connection_supervisor([
            {:session_ref, updated_state.session_ref},
            {:parent, self()} | updated_state.opts
          ])

        transition_actions = [
          {:next_event, :internal, :connect}
        ]

        {:ok, :connecting, updated_state, transition_actions}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, _state, %State{handler: handler}) do
    _ignored =
      if function_exported?(handler.module, :terminate, 2) do
        Handler.execute_terminate(handler, reason)
      end
  end

  @impl true
  def handle_event(:info, {:incoming, package}, _, _data) when is_binary(package) do
    next_actions = [{:next_event, :internal, {:received, Package.decode(package)}}]
    {:keep_state_and_data, next_actions}
  end

  # connection acknowledgement
  def handle_event(
        :internal,
        {:received, %Package.Connack{reason: connection_result} = connack},
        :connecting,
        %State{
          connect: %Package.Connect{} = connect,
          handler: handler
        } = data
      ) do
    case Handler.execute_handle_connack(handler, connack) do
      {:ok, %Handler{} = updated_handler, next_actions} when connection_result == :success ->
        data = %State{
          data
          | backoff: Backoff.reset(data.backoff),
            handler: updated_handler,
            info: Info.merge(connect, connack)
        }

        next_actions = [
          {:next_event, :internal, :setup_keep_alive_timer},
          {:next_event, :internal, {:execute_handler, {:connection, :up}}}
          | wrap_next_actions(next_actions)
        ]

        {:next_state, :connected, data, next_actions}

      {:stop, reason, %Handler{} = updated_handler} ->
        data = %State{data | handler: updated_handler}
        {:stop, reason, data}

      {:error, reason} ->
        {:stop, reason, data}
    end
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

  # get status =========================================================
  def handle_event({:call, from}, :get_info, :connected, %{receiver: {receiver_pid, _}} = data) do
    next_actions = [{:reply, from, {:connected, struct(data.info, receiver_pid: receiver_pid)}}]

    {:keep_state_and_data, next_actions}
  end

  def handle_event({:call, from}, :get_info, state, _data) do
    next_actions = [{:reply, from, state}]

    {:keep_state_and_data, next_actions}
  end

  # a process request the connection; postpone if we are not yet connected
  def handle_event({:call, _from}, :get_connection, :connecting, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event({:call, from}, :get_connection, :connected, data) do
    transition_actions = [{:reply, from, {:ok, data.connection}}]
    {:keep_state, data, transition_actions}
  end

  # publish packages ===================================================
  def handle_event(
        :internal,
        {:received, %Package.Publish{qos: 0, dup: false} = publish},
        _,
        %State{handler: handler} = data
      ) do
    case Handler.execute_handle_publish(handler, publish) do
      {:ok, %Handler{} = updated_handler, next_actions} ->
        updated_data = %State{data | handler: updated_handler}
        {:keep_state, updated_data, wrap_next_actions(next_actions)}

      {:error, reason} ->
        {:stop, reason, data}
    end
  end

  # incoming publish QoS=1 ---------------------------------------------
  def handle_event(
        :internal,
        {:received, %Package.Publish{identifier: id, qos: 1} = publish},
        _,
        %State{
          connection: {transport, socket},
          handler: handler,
          session: session
        } = data
      ) do
    case Session.track(session, {:incoming, publish}) do
      {{:cont, publish}, session} ->
        case Handler.execute_handle_publish(handler, publish) do
          {:ok, %Package.Puback{identifier: ^id} = puback, updated_handler, next_actions} ->
            # respond with a puback
            {{:cont, _puback}, session} = Session.progress(session, {:outgoing, puback})
            :ok = transport.send(socket, Package.encode(puback))
            {:ok, session} = Session.release(session, id)
            # - - -
            updated_data = %State{data | handler: updated_handler, session: session}
            {:keep_state, updated_data, wrap_next_actions(next_actions)}

            # handle stop
        end
    end
  end

  # outgoing publish QoS=1 ---------------------------------------------
  def handle_event(
        {:call, {_caller_pid, ref} = from},
        {:publish, %Package.Publish{qos: 1} = publish},
        _,
        %State{
          connection: {transport, socket},
          session: session,
          pending_refs: pending
        } = data
      ) do
    case Session.track(session, {:outgoing, publish}) do
      {{:cont, %Package.Publish{identifier: id} = publish}, session} ->
        :ok = transport.send(socket, Package.encode(publish))
        next_actions = [{:reply, from, {:ok, {session.client_id, ref}}}]
        data = %State{data | session: session, pending_refs: Map.put_new(pending, id, from)}
        {:keep_state, data, next_actions}
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Puback{identifier: id} = puback},
        _,
        %State{session: session, handler: handler, pending_refs: pending} = data
      ) do
    case Map.pop(pending, id) do
      {caller, pending} ->
        {{:cont, puback}, session} = Session.progress(session, {:incoming, puback})
        data = %State{data | pending_refs: pending, session: session}

        if function_exported?(handler.module, :handle_puback, 2) do
          case Handler.execute_handle_puback(handler, puback) do
            {:ok, %Handler{} = updated_handler, next_actions} ->
              next_actions = [
                {:next_event, :internal, {:reply, caller, Package.Publish, :ok}}
                | wrap_next_actions(next_actions)
              ]

              {:ok, session} = Session.release(session, id)
              updated_data = %State{data | handler: updated_handler, session: session}
              {:keep_state, updated_data, next_actions}

            {:error, reason} ->
              # todo
              updated_data = %State{data | session: session}
              {:stop, reason, updated_data}
          end
        else
          {:ok, session} = Session.release(session, id)
          next_actions = [{:next_event, :internal, {:reply, caller, Package.Publish, :ok}}]
          {:keep_state, %State{data | session: session}, next_actions}
        end
    end
  end

  # incoming publish QoS=2 ---------------------------------------------
  # TODO handle duplicate messages
  def handle_event(
        :internal,
        {:received, %Package.Publish{qos: 2, identifier: id} = publish},
        _,
        %State{connection: {transport, socket}, handler: handler, session: session} = data
      ) do
    case Session.track(session, {:incoming, publish}) do
      {{:cont, publish}, session} ->
        case Handler.execute_handle_publish(handler, publish) do
          {:ok, %Package.Pubrec{identifier: ^id} = pubrec, %Handler{} = updated_handler,
           next_actions} ->
            # respond with pubrec
            {{:cont, pubrec}, session} = Session.progress(session, {:outgoing, pubrec})
            :ok = transport.send(socket, Package.encode(pubrec))
            # - - -
            updated_data = %State{data | handler: updated_handler, session: session}
            {:keep_state, updated_data, wrap_next_actions(next_actions)}
        end
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Pubrel{identifier: id} = pubrel},
        _,
        %State{connection: {transport, socket}, handler: handler, session: session} = data
      ) do
    {{:cont, pubrel}, session} = Session.progress(session, {:incoming, pubrel})

    if function_exported?(handler.module, :handle_pubrel, 2) do
      case Handler.execute_handle_pubrel(handler, pubrel) do
        {:ok, %Package.Pubcomp{identifier: ^id} = pubcomp, %Handler{} = updated_handler,
         next_actions} ->
          # dispatch the pubcomp
          {{:cont, pubcomp}, session} = Session.progress(session, {:outgoing, pubcomp})
          :ok = transport.send(socket, Package.encode(pubcomp))
          {:ok, session} = Session.release(session, id)
          updated_data = %State{data | handler: updated_handler, session: session}
          {:keep_state, updated_data, wrap_next_actions(next_actions)}

        {:error, reason} ->
          # todo
          {:stop, reason, data}
      end
    else
      pubcomp = %Package.Pubcomp{identifier: id}
      {{:cont, pubcomp}, session} = Session.progress(session, {:outgoing, pubcomp})
      :ok = transport.send(socket, Package.encode(pubcomp))
      {:ok, session} = Session.release(session, id)
      updated_data = %State{data | session: session}
      {:keep_state, updated_data}
    end
  end

  # outgoing publish QoS=2 ---------------------------------------------
  def handle_event(
        {:call, {_caller_pid, ref} = from},
        {:publish, %Package.Publish{qos: 2, dup: false} = publish},
        _,
        %State{
          connection: {transport, socket},
          session: session,
          pending_refs: pending
        } = data
      ) do
    case Session.track(session, {:outgoing, publish}) do
      {{:cont, %Package.Publish{identifier: id} = publish}, session} ->
        :ok = transport.send(socket, Package.encode(publish))
        next_actions = [{:reply, from, {:ok, {session.client_id, ref}}}]
        data = %State{data | session: session, pending_refs: Map.put_new(pending, id, from)}
        {:keep_state, data, next_actions}
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Pubrec{identifier: id, reason: reason} = pubrec},
        _,
        %State{connection: {transport, socket}, session: session, handler: handler} = data
      ) do
    {{:cont, pubrec}, session} = Session.progress(session, {:incoming, pubrec})
    data = %State{data | session: session}

    if function_exported?(handler.module, :handle_pubrec, 2) do
      case Handler.execute_handle_pubrec(handler, pubrec) do
        {:ok, %Package.Pubrel{identifier: ^id} = pubrel, %Handler{} = updated_handler,
         next_actions}
        when reason == :success or reason == {:refused, :no_matching_subscribers} ->
          # NOTICE that we do allow the "no matching subscribers"
          # reason as a success; "...in the case of QoS 2 PUBLISH it
          # is PUBCOMP or a PUBREC with a Reason Code of 128 or
          # greater"
          {{:cont, pubrel}, session} = Session.progress(session, {:outgoing, pubrel})
          :ok = transport.send(socket, Package.encode(pubrel))
          data = %State{data | session: session, handler: updated_handler}
          {:keep_state, data, wrap_next_actions(next_actions)}

        {:ok, %Package.Pubrel{}, _updated_handler, _} ->
          # user error; should not respond with pubrel if the publish failed
          # TODO add a test case returning ok-pubrel on rejected pubrec
          {:ok, session} = Session.release(session, id)
          data = %State{data | session: session}
          {:stop, reason, data}

        {:error, reason} ->
          # todo
          {:stop, reason, data}
      end
    else
      pubrel = %Package.Pubrel{identifier: id}
      {{:cont, pubrel}, session} = Session.progress(session, {:outgoing, pubrel})
      :ok = transport.send(socket, Package.encode(pubrel))
      data = %State{data | session: session}
      {:keep_state, data}
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Pubcomp{identifier: id} = pubcomp},
        :connected,
        %State{session: session, pending_refs: pending, handler: handler} = data
      ) do
    case Map.pop(pending, id) do
      {caller, pending} ->
        {{:cont, pubcomp}, session} = Session.progress(session, {:incoming, pubcomp})
        data = %State{data | pending_refs: pending, session: session}

        if function_exported?(handler.module, :handle_pubcomp, 2) do
          case Handler.execute_handle_pubcomp(handler, pubcomp) do
            {:ok, %Handler{} = updated_handler, next_actions} ->
              {:ok, session} = Session.release(session, id)

              data = %State{data | session: session, handler: updated_handler}

              next_actions = [
                {:next_event, :internal, {:reply, caller, Package.Publish, :ok}}
                | wrap_next_actions(next_actions)
              ]

              {:keep_state, data, next_actions}

            {:error, reason} ->
              # todo
              {:stop, reason, data}
          end
        else
          {:ok, session} = Session.release(session, id)
          data = %State{data | session: session}
          next_actions = [{:next_event, :internal, {:reply, caller, Package.Publish, :ok}}]
          {:keep_state, data, next_actions}
        end
    end
  end

  # subscription logic
  def handle_event(
        {:call, from},
        {:subscribe, %Package.Subscribe{topics: []}, _opts},
        :connected,
        _data
      ) do
    # This should not really be able to happen as the API will not
    # allow the user to specify an empty list, but this is added for
    # good measure
    next_actions = [{:reply, from, {:error, :empty_topic_filter_list}}]
    {:keep_state_and_data, next_actions}
  end

  def handle_event(
        {:call, {_, ref} = from},
        {:subscribe, %Package.Subscribe{} = subscribe, _opts},
        :connected,
        %State{
          connection: {transport, socket},
          session: session
        } = data
      ) do
    case Info.Capabilities.validate(data.info.capabilities, subscribe) do
      :valid ->
        case Session.track(session, {:outgoing, subscribe}) do
          {{:cont, %Package.Subscribe{identifier: id} = subscribe}, session} ->
            :ok = transport.send(socket, Package.encode(subscribe))
            pending = Map.put_new(data.pending_refs, id, {from, subscribe})
            state = %State{data | pending_refs: pending, session: session}
            next_actions = [{:reply, from, {:ok, {session.client_id, ref}}}]
            {:keep_state, state, next_actions}
        end

      {:invalid, reasons} ->
        reply = {:error, {:subscription_failure, reasons}}
        next_actions = [{:reply, from, reply}]
        {:keep_state_and_data, next_actions}
    end
  end

  def handle_event({:call, _}, {:subscribe, _, _}, _state_name, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event(
        :internal,
        {:subscribe, %Package.Subscribe{} = subscribe, _opts},
        :connected,
        %State{
          connection: {transport, socket},
          session: session
        } = data
      ) do
    case Info.Capabilities.validate(data.info.capabilities, subscribe) do
      :valid ->
        case Session.track(session, {:outgoing, subscribe}) do
          {{:cont, %Package.Subscribe{identifier: id} = subscribe}, session} ->
            caller = {self(), make_ref()}
            :ok = transport.send(socket, Package.encode(subscribe))
            pending = Map.put_new(data.pending_refs, id, {caller, subscribe})
            {:keep_state, %State{data | pending_refs: pending, session: session}}
        end

      {:invalid, reasons} ->
        next_actions = [{:error, {:subscription_failure, reasons}}]
        {:keep_state_and_data, next_actions}
    end
  end

  def handle_event(:internal, {:subscribe, _, _}, _state_name, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event(
        :internal,
        {:received, %Package.Suback{identifier: id} = suback},
        :connected,
        %State{session: session, handler: handler, pending_refs: pending, info: info} = data
      ) do
    case Map.pop(pending, id) do
      {{caller, %Package.Subscribe{identifier: ^id} = subscribe}, pending} ->
        {pid, msg_ref} = caller

        {{:cont, suback}, session} = Session.progress(session, {:incoming, suback})

        data = %State{data | pending_refs: pending, session: session}

        updated_subscriptions =
          subscribe.topics
          |> Enum.zip(suback.acks)
          |> Enum.reduce(data.info.subscriptions, fn
            {{topic, opts}, {:ok, accepted_qos}}, acc ->
              Map.put(acc, topic, Keyword.replace!(opts, :qos, accepted_qos))

            {_, {:error, _}}, acc ->
              acc
          end)

        case Handler.execute_handle_suback(handler, subscribe, suback) do
          {:ok, %Handler{} = updated_handler, next_actions} ->
            data = %State{
              data
              | handler: updated_handler,
                info: put_in(info.subscriptions, updated_subscriptions)
            }

            next_actions = [
              {:next_event, :internal, {:reply, {pid, msg_ref}, Package.Suback, :ok}}
              | wrap_next_actions(next_actions)
            ]

            {:ok, session} = Session.release(session, id)

            {:keep_state, %State{data | session: session}, next_actions}

          {:error, reason} ->
            # todo
            {:stop, reason, data}
        end
    end
  end

  def handle_event(
        {:call, {_pid, ref} = from},
        {:unsubscribe, unsubscribe, opts},
        :connected,
        %State{
          session: session,
          connection: {transport, socket},
          pending_refs: pending
        } = data
      ) do
    _timeout = Keyword.get(opts, :timeout, 5000)

    case Session.track(session, {:outgoing, unsubscribe}) do
      {{:cont, %Package.Unsubscribe{identifier: id} = unsubscribe}, session} ->
        :ok = transport.send(socket, Package.encode(unsubscribe))
        pending = Map.put_new(pending, id, {from, unsubscribe})
        next_actions = [{:reply, from, {:ok, {session.client_id, ref}}}]
        {:keep_state, %State{data | pending_refs: pending, session: session}, next_actions}
    end
  end

  def handle_event(
        :internal,
        {:unsubscribe, unsubscribe, opts},
        :connected,
        %State{
          session: session,
          connection: {transport, socket},
          pending_refs: pending
        } = data
      ) do
    _timeout = Keyword.get(opts, :timeout, 5000)

    case Session.track(session, {:outgoing, unsubscribe}) do
      {{:cont, %Package.Unsubscribe{identifier: id} = unsubscribe}, session} ->
        :ok = transport.send(socket, Package.encode(unsubscribe))
        caller = {self(), make_ref()}
        pending = Map.put_new(pending, id, {caller, unsubscribe})
        {:keep_state, %State{data | pending_refs: pending, session: session}}
    end
  end

  def handle_event(
        :internal,
        {:received, %Package.Unsuback{identifier: id, results: [_ | _]} = unsuback},
        :connected,
        %State{session: session, handler: handler, pending_refs: pending, info: info} = data
      ) do
    case Map.pop(pending, id) do
      {{caller, %Package.Unsubscribe{identifier: ^id} = unsubscribe}, pending} ->
        {pid, msg_ref} = caller
        {{:cont, unsuback}, session} = Session.progress(session, {:incoming, unsuback})
        data = %State{data | pending_refs: pending, session: session}

        # When updating the internal subscription state tracker we will
        # disregard the unsuccessful unsubacks, as we can assume it wasn't
        # in the subscription list to begin with, or that we are still
        # subscribed as we are not autorized to unsubscribe for the given
        # topic; one exception is when the server report no subscription
        # existed; then we will update the client state
        to_remove =
          for {topic, result} <- Enum.zip(unsubscribe.topics, unsuback.results),
              match?(
                reason when reason == :success or reason == {:error, :no_subscription_existed},
                result
              ),
              do: topic

        # TODO handle the unsuback error cases !
        subscriptions = Map.drop(data.info.subscriptions, to_remove)

        case Handler.execute_handle_unsuback(handler, unsubscribe, unsuback) do
          {:ok, %Handler{} = updated_handler, next_actions} ->
            {:ok, session} = Session.release(session, id)

            data = %State{
              data
              | handler: updated_handler,
                session: session,
                info: put_in(info.subscriptions, subscriptions)
            }

            next_actions = [
              {:next_event, :internal, {:reply, {pid, msg_ref}, Package.Unsuback, :ok}}
              | wrap_next_actions(next_actions)
            ]

            {:keep_state, data, next_actions}

          {:error, reason} ->
            # todo
            {:stop, reason, data}
        end
    end
  end

  # Pass on the result of an operation if we have a calling pid. This
  # can happen if a process order the connection to subscribe to a
  # topic, or unsubscribe, etc.
  def handle_event(
        :internal,
        {:reply, caller, topic, payload},
        _current_state,
        %State{session: session}
      ) do
    case caller do
      {pid, _ref} when pid != self() ->
        _ = send_reply(session.client_id, caller, topic, payload)
        :keep_state_and_data

      _otherwise ->
        :keep_state_and_data
    end
  end

  def handle_event({:call, from}, :subscriptions, _, %State{
        info: %Info{subscriptions: subscriptions}
      }) do
    next_actions = [{:reply, from, subscriptions}]
    {:keep_state_and_data, next_actions}
  end

  # User actions are actions returned by the user defined callbacks;
  # They inform the connection to perform an action, such as
  # subscribing to a topic, and they are validated by the handler
  # module, so there is no need to coerce here
  def handle_event(
        :internal,
        {:user_action, action},
        _,
        %State{connection: {transport, socket}} = state
      ) do
    case action do
      {:subscribe, topic, opts} when is_binary(topic) ->
        {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)
        subscribe = %Package.Subscribe{identifier: identifier, topics: [{topic, opts}]}
        next_actions = [{:next_event, :internal, {:subscribe, subscribe, opts}}]
        {:keep_state_and_data, next_actions}

      {:unsubscribe, topic, opts} when is_binary(topic) ->
        {identifier, opts} = Keyword.pop_first(opts, :identifier, nil)
        subscribe = %Package.Unsubscribe{identifier: identifier, topics: [topic]}
        next_actions = [{:next_event, :internal, {:unsubscribe, subscribe, opts}}]
        {:keep_state_and_data, next_actions}

      :disconnect ->
        disconnect = %Package.Disconnect{reason: :normal_disconnection}
        # TODO consider draining messages with qos
        :ok = transport.send(socket, Package.encode(disconnect))
        {:stop, :normal}

      {:eval, fun} when is_function(fun, 1) ->
        try do
          apply(fun, [state])
        rescue
          _disregard -> nil
        end

        {:keep_state, state}
    end
  end

  # dispatch to user defined handler
  def handle_event(
        :internal,
        {:execute_handler, {:connection, status}},
        :connected,
        %State{handler: handler} = data
      ) do
    if function_exported?(handler.module, :status_change, 2) do
      case Handler.execute_status_change(handler, status) do
        {:ok, %Handler{} = updated_handler, next_actions} ->
          updated_data = %State{data | handler: updated_handler}
          {:keep_state, updated_data, wrap_next_actions(next_actions)}

          # handle stop
      end
    else
      :keep_state_and_data
    end
  end

  # connection logic ===================================================
  def handle_event(:internal, :connect, :connecting, %State{} = data) do
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
        %State{
          connect: connect,
          receiver: {receiver_pid, _mon_ref}
        } = data
      ) do
    case Receiver.connect(receiver_pid) do
      {:ok, {transport, socket} = connection} ->
        # TODO: send this to the client handler allowing the user to
        # specify a custom connect package
        :ok = transport.send(socket, Package.encode(connect))

        new_data = %State{
          data
          | connect: %Connect{connect | clean_start: false},
            connection: connection
        }

        {:keep_state, new_data}

      {:error, {:stop, reason}} ->
        {:stop, reason, data}

      {:error, {:retry, _reason}} ->
        transition_actions = [{:next_event, :internal, :connect}]
        {:keep_state, data, transition_actions}
    end
  end

  # disconnect protocol messages ---------------------------------------
  def handle_event(
        {:call, from},
        {:disconnect, %Package.Disconnect{} = disconnect},
        :connected,
        %State{connection: {transport, socket}} = data
      ) do
    # TODO consider draining messages with QoS
    :ok = transport.send(socket, Package.encode(disconnect))

    {:stop_and_reply, :shutdown, [{:reply, from, :ok}], data}
  end

  def handle_event(
        {:call, _from},
        {:disconnect, _reason},
        _,
        %State{}
      ) do
    {:keep_state_and_data, [:postpone]}
  end

  # ping handling ------------------------------------------------------
  def handle_event({:call, {_, ref} = from}, :ping, :connected, %State{session: session} = data) do
    next_actions = [{:reply, from, {:ok, {session.client_id, ref}}}]

    case data.ping do
      {:idle, awaiting} ->
        next_actions = [
          {:next_event, :internal, :trigger_keep_alive}
          | next_actions
        ]

        {:keep_state, %State{data | ping: {:idle, [from | awaiting]}}, next_actions}

      {{:pinging, start_time}, awaiting} ->
        {:keep_state, %State{data | ping: {{:pinging, start_time}, [from | awaiting]}},
         next_actions}
    end
  end

  # not connected yet
  def handle_event({:call, from}, :ping, _, %State{}) do
    next_actions = [{:reply, from, {:error, :not_connected}}]
    {:keep_state_and_data, next_actions}
  end

  # keep alive ---------------------------------------------------------
  def handle_event(
        :internal,
        :setup_keep_alive_timer,
        :connected,
        %State{info: %Info{keep_alive: keep_alive}}
      ) do
    next_actions = [{:state_timeout, keep_alive * 1000, :keep_alive}]
    {:keep_state_and_data, next_actions}
  end

  def handle_event(:internal, :setup_keep_alive_timer, _other_states, _data) do
    :keep_state_and_data
  end

  def handle_event(:internal, :trigger_keep_alive, :connected, _data) do
    # set the keep alive timeout to trigger instantly
    next_actions = [{:state_timeout, 0, :keep_alive}]
    {:keep_state_and_data, next_actions}
  end

  def handle_event(:internal, :trigger_keep_alive, _other_states, _data) do
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
        %State{ping: {{:pinging, start_time}, awaiting}, session: session} = data
      ) do
    round_trip_time =
      (System.monotonic_time() - start_time)
      |> System.convert_time_unit(:native, :microsecond)

    # reply to the clients
    Enum.each(awaiting, &send_reply(session.client_id, &1, Package.Pingreq, round_trip_time))

    next_actions = [{:next_event, :internal, :setup_keep_alive_timer}]

    {:keep_state, %State{data | ping: {:idle, []}}, next_actions}
  end

  # server initiated disconnect packages
  def handle_event(
        :internal,
        {:received, %Package.Disconnect{} = disconnect},
        _current_state,
        %State{handler: handler} = data
      ) do
    case Handler.execute_handle_disconnect(handler, {:server, disconnect}) do
      {:ok, updated_handler, next_actions} ->
        {:keep_state, %State{data | handler: updated_handler}, wrap_next_actions(next_actions)}

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

  defp await_and_monitor_receiver(%State{receiver: nil} = data) do
    session_ref = data.session_ref

    receive do
      {{Tortoise, ^session_ref}, Receiver, {:ready, pid}} ->
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

  # wrapping the user specified next actions in gen_statem next actions;
  # this is used in all the handle callback functions, so we inline it
  defp wrap_next_actions(next_actions) do
    for action <- next_actions do
      {:next_event, :internal, {:user_action, action}}
    end
  end

  defp send_reply(client_id, {caller, ref}, topic, payload)
       when is_pid(caller) and is_reference(ref) do
    send(caller, {{Tortoise, client_id}, {topic, ref}, payload})
  end

  @compile {:inline, wrap_next_actions: 1, send_reply: 4}
end
