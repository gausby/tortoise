defmodule Tortoise.Handler do
  @moduledoc """
  User defined callback module for handling connection life cycle events.

  `Tortoise.Handler` defines a behaviour which can be given to a
  `Tortoise.Connection`. This allow the user to implement
  functionality for events happening in the life cycle of the
  connection, the provided callbacks are:

    - `init/1` and `terminate/2` are called when the connection is
      started and stopped. Parts that are setup in `init/1` can be
      torn down in `terminate/2`. Notice that the connection process
      is not terminated if the connection to the broker is lost;
      `Tortoise` will attempt to reconnect, and events that should
      happen when the connection goes offline should be set up using
      the `connection/3` callback.

    - `connection/3` is called when the connection is `:up` or
      `:down`, allowing for functionality to be run when the
      connection state changes.

    - `subscription/3` is called when a topic filter subscription
      changes status, so this callback can be used to control the
      life-cycle of a subscription, allowing us to implement custom
      behavior for when the subscription is accepted, declined, as
      well as unsubscribed.

    - `handle_message/3` is run when the client receive a message on
      one of the subscribed topic filters.

  Because the callback-module will run inside the connection
  controller process, which also handles the routing of protocol
  messages (such as publish acknowledge messages) it is important that
  the callbacks do not call functions that will block the process,
  especially for clients that subscribe to topics with heavy
  traffic.

  Technically it would be possible to run the callback module in a
  different process than the controller process, but it has been
  decided to keep it on the controller as we otherwise would have to
  copy every message evaluated by the connection to another
  process. It is much better to let the end-user handle the
  dispatching to other parts of the system while we are evaluating
  what to do with the process anyways with the caveats:

     - The callbacks should not block the controller

     - it is not possible to call the (un)subscribe and publish
       functions from within a callback as they will block the
       controller.

  While it is not possible to subscribe and unsubscribe in the handler
  process using the `Tortoise.subscribe/3` and
  `Tortoise.unsubscribe/3` it is possible to make changes to the
  subscription list via `:gen_statem` inspired *next_actions*.

  ## Next actions

  In some situations one would like to subscribe or unsubscribe a
  filter topic when a certain event happens on the client. The
  functions for interacting with the MQTT broker, defined on the
  `Tortoise`-module are for the most part blocking operations, or
  require the user to peek into the process mailbox to fetch the
  result of the operation. To allow for changes in the subscriptions
  one can define a set of next actions that should happen as part of
  the return value to the `handle_message/3`, `subscription/3`, and
  `connection/3` callbacks by returning a `{:ok, state, next_actions}`
  where `next_actions` is a list of commands of:

    - `{:subscribe, topic_filter, qos: qos, timeout: 5000}` where
      `topic_filter` is a binary containing a valid MQTT topic filter,
      and `qos` is the desired quality of service (0..2). The timeout
      is the amount of time in milliseconds we are willing to wait for
      a response to the request.

    - `{:unsubscribe, topic_filter}` where `topic_filter` is a binary
      containing the name of the subscription we want to unsubscribe
      from.

  If we want to unsubscribe from the current topic when we receive a
  message on it we could write a `handle_message/3` as follows:

      def handle_message(topic, _payload, state) do
        topic = Enum.join(topic, "/")
        next_actions = [{:unsubscribe, topic}]
        {:ok, state, next_actions}
      end

  Note that the `topic` is received as a list of topic levels, and
  that the next actions has to be a list, even if there is only one
  next action; multiple actions can be given at once. Read more about
  this in the `handle_message/3` documentation.
  """

  alias Tortoise.Package

  @enforce_keys [:module, :initial_args]
  defstruct module: nil, state: nil, initial_args: []

  # Helper for building a Handler struct so we can keep it as an
  # opaque type in the system.
  @doc false
  def new({module, args}) when is_atom(module) and is_list(args) do
    %__MODULE__{module: module, initial_args: args}
  end

  # identity
  def new(%__MODULE__{} = handler), do: handler

  # todo; define topic_filter and qos in another module and reference
  #       them from there
  @typep topic_filter() :: binary()

  @type topic_opts() ::
          {:qos, Tortoise.qos()}
          | {:timeout, timeout()}
  @type next_action() ::
          {:subscribe, topic_filter(), [topic_opts()]}
          | {:unsubscribe, topic_filter()}

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Tortoise.Handler

      @impl true
      def init(state) do
        {:ok, state}
      end

      @impl true
      def terminate(_reason, _state) do
        :ok
      end

      @impl true
      def connection(_status, state) do
        {:ok, state}
      end

      @impl true
      def subscription(_status, _topic_filter, state) do
        {:ok, state}
      end

      @impl true
      def handle_message(_topic, _payload, state) do
        {:ok, state}
      end

      defoverridable Tortoise.Handler
    end
  end

  @doc """
  Invoked when the connection is started.

  `args` is the argument passed in from the connection configuration.

  Returning `{:ok, state}` will let the MQTT connection receive data
  from the MQTT broker, and the value contained in `state` will be
  used as the process state.
  """
  @callback init(args :: term) :: {:ok, state}
            when state: any

  @doc """
  Invoked when the connection status changes.

  `status` is one of `:up` or `:down`, where up means we have an open
  connection to the MQTT broker, and down means the connection is
  temporary down. The connection process will attempt to reestablish
  the connection.

  Returning `{:ok, new_state}` will set the state for later
  invocations.

  Returning `{:ok, new_state, next_actions}`, where `next_actions` is
  a list of next actions such as `{:unsubscribe, "foo/bar"}` will
  result in the state being returned and the next actions performed.
  """
  @callback connection(status, state :: term) ::
              {:ok, new_state}
              | {:ok, new_state, [next_action()]}
            when status: :up | :down,
                 new_state: term

  @doc """
  Invoked when the subscription of a topic filter changes status.

  The `status` of a subscription can be one of:

    - `:up`, triggered when the subscription has been accepted by the
      MQTT broker with the requested quality of service

    - `{:warn, [requested: req_qos, accepted: qos]}`, triggered when
       the subscription is accepted by the MQTT broker, but with a
       different quality of service `qos` than the one requested
       `req_qos`

    - `{:error, reason}`, triggered when the subscription is rejected
      with the reason `reason` such as `:access_denied`

    - `:down`, triggered when the subscription of the given topic
      filter has been successfully acknowledged as unsubscribed by the
      MQTT broker

  The `topic_filter` is the topic filter in question, and the `state`
  is the internal state being passed through transitions.

  Returning `{:ok, new_state}` will set the state for later
  invocations.

  Returning `{:ok, new_state, next_actions}`, where `next_actions` is
  a list of next actions such as `{:unsubscribe, "foo/bar"}` will
  result in the state being returned and the next actions performed.
  """
  @callback subscription(status, topic_filter(), state :: term) ::
              {:ok, new_state}
              | {:ok, new_state, [next_action()]}
            when status:
                   :up
                   | :down
                   | {:warn, [requested: Tortoise.qos(), accepted: Tortoise.qos()]}
                   | {:error, term()},
                 new_state: term

  @doc """
  Invoked when messages are published to subscribed topics.

  The `topic` comes in the form of a list of binaries, making it
  possible to pattern match on the topic levels of the retrieved
  message, store the individual topic levels as variables and use it
  in the function body.

  `Payload` is a binary. MQTT 3.1.1 does not specify any format of the
  payload, so it has to be decoded and validated depending on the
  needs of the application.

  In an example where we are already subscribed to the topic filter
  `room/+/temp` and want to dispatch the received messages to a
  `Temperature` application we could set up our `handle_message` as
  such:

      def handle_message(["room", room, "temp"], payload, state) do
        :ok = Temperature.record(room, payload)
        {:ok, state}
      end

  Notice; the `handle_message/3`-callback run inside the connection
  controller process, so for handlers that are subscribing to topics
  with heavy traffic should do as little as possible in the callback
  handler and dispatch to other parts of the application using
  non-blocking calls.

  Returning `{:ok, new_state}` will reenter the loop and set the state
  for later invocations.

  Returning `{:ok, new_state, next_actions}`, where `next_actions` is
  a list of next actions such as `{:unsubscribe, "foo/bar"}` will
  reenter the loop and perform the listed actions.
  """
  @callback handle_message(topic, payload, state :: term) ::
              {:ok, new_state}
              | {:ok, new_state, [next_action()]}
            when new_state: term,
                 topic: [binary()],
                 payload: binary()

  @doc """
  Invoked when the connection process is about to exit.

  If anything is setup during the `init/1` callback it should get
  cleaned up during the `terminate/2` callback.
  """
  @callback terminate(reason, state :: term) :: ignored
            when reason: :normal | :shutdown | {:shutdown, term},
                 ignored: term

  @doc false
  def execute(handler, :init) do
    case apply(handler.module, :init, [handler.initial_args]) do
      {:ok, initial_state} ->
        {:ok, %__MODULE__{handler | state: initial_state}}
    end
  end

  def execute(handler, {:connection, status}) do
    handler.module
    |> apply(:connection, [status, handler.state])
    |> handle_result(handler)
  end

  def execute(handler, {:publish, %Package.Publish{} = publish}) do
    topic_list = String.split(publish.topic, "/")

    handler.module
    |> apply(:handle_message, [topic_list, publish.payload, handler.state])
    |> handle_result(handler)
  end

  def execute(handler, {:unsubscribe, unsubacks}) do
    Enum.reduce(unsubacks, {:ok, handler}, fn topic_filter, {:ok, handler} ->
      handler.module
      |> apply(:subscription, [:down, topic_filter, handler.state])
      |> handle_result(handler)

      # _, {:stop, acc} ->
      #   {:stop, acc}
    end)
  end

  def execute(handler, {:subscribe, subacks}) do
    subacks
    |> flatten_subacks()
    |> Enum.reduce({:ok, handler}, fn {op, topic_filter}, {:ok, handler} ->
      handler.module
      |> apply(:subscription, [op, topic_filter, handler.state])
      |> handle_result(handler)

      # _, {:stop, acc} ->
      #   {:stop, acc}
    end)
  end

  def execute(handler, {:terminate, reason}) do
    _ignored = apply(handler.module, :terminate, [reason, handler.state])
    :ok
  end

  # Subacks will come in a map with three keys in the form of tuples
  # where the fist element is one of `:ok`, `:warn`, or `:error`. This
  # is done to make it easy to pattern match in other parts of the
  # system, and error out early if the result set contain errors. In
  # this part of the system it is more convenient to transform the
  # data to a flat list containing tuples of `{operation, data}` so we
  # can reduce the handler state to collect the possible next actions,
  # and pass through if there is an :error or :disconnect return.
  defp flatten_subacks(subacks) do
    Enum.reduce(subacks, [], fn
      {_, []}, acc ->
        acc

      {:ok, entries}, acc ->
        for {topic_filter, _qos} <- entries do
          {:up, topic_filter}
        end ++ acc

      {:warn, entries}, acc ->
        for {topic_filter, warning} <- entries do
          {{:warn, warning}, topic_filter}
        end ++ acc

      {:error, entries}, acc ->
        for {reason, {topic_filter, _qos}} <- entries do
          {{:error, reason}, topic_filter}
        end ++ acc
    end)
  end

  # handle the user defined return from the callback
  defp handle_result({:ok, updated_state}, handler) do
    {:ok, %__MODULE__{handler | state: updated_state}}
  end

  defp handle_result({:ok, updated_state, next_actions}, handler)
       when is_list(next_actions) do
    case Enum.split_with(next_actions, &valid_next_action?/1) do
      {next_actions, []} ->
        # send the next actions to the process mailbox. Notice that
        # this code is run in the context of the connection controller
        for action <- next_actions, do: send(self(), {:next_action, action})
        {:ok, %__MODULE__{handler | state: updated_state}}

      {_, errors} ->
        {:error, {:invalid_next_action, errors}}
    end
  end

  defp valid_next_action?({:subscribe, topic, opts}) do
    is_binary(topic) and is_list(opts)
  end

  defp valid_next_action?({:unsubscribe, topic}) do
    is_binary(topic)
  end

  defp valid_next_action?(_otherwise), do: false
end
