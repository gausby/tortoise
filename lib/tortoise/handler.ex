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

    - `handle_publish/3` is run when the client receive a publish on
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
  the return value to the `handle_publish/3`, `subscription/3`, and
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
  publish on it we could write a `handle_publish/3` as follows:

      def handle_publish(_, %{topic: topic}, state) do
        next_actions = [{:unsubscribe, topic}]
        {:cont, state, next_actions}
      end

  The next actions has to be a list, even if there is only one next
  action; multiple actions can be given at once. Read more about this
  in the `handle_publish/3` documentation.
  """

  alias Tortoise.Package

  @typedoc """
  Data structure describing the user defined callback handler

  The data structure describe the current state as well as its initial
  arguments and the module driving the handler. This allow Tortoise to
  restart the handler if needed be.
  """
  @type t :: %__MODULE__{
          module: module(),
          initial_args: term(),
          state: term()
        }
  @enforce_keys [:module, :initial_args]
  defstruct module: nil, state: nil, initial_args: []

  # Helper for building a Handler struct so we can keep it as an
  # opaque type in the system.
  @doc false
  @spec new({module(), args :: term()}) :: t
  def new({module, args}) when is_atom(module) and is_list(args) do
    %__MODULE__{module: module, initial_args: args}
  end

  # identity
  def new(%__MODULE__{} = handler), do: handler

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Tortoise.Handler

      @impl true
      def init(state) do
        {:ok, state}
      end

      @impl true
      def handle_connack(%Package.Connack{reason: :success}, state) do
        {:cont, state}
      end

      def handle_connack(%Package.Connack{reason: {:refused, reason}}, _state) do
        # todo, we could categorize the reasons into user error,
        # network error, etc error...
        case reason do
          :unsupported_protocol_version ->
            {:error, {:connection_failed, :unsupported_protocol_version}}

          :not_authorized ->
            {:error, {:connection_failed, :not_authorized}}

          :server_unavailable ->
            {:error, {:connection_failed, :server_unavailable}}

          :client_identifier_not_valid ->
            {:error, {:connection_failed, :client_identifier_not_valid}}

          :bad_user_name_or_password ->
            {:error, {:connection_failed, :bad_user_name_or_password}}

            # todo, list not exhaustive
        end
      end

      @impl true
      def handle_publish(_topic_list, _publish, state) do
        {:cont, state}
      end

      @impl true
      def handle_suback(_subscribe, _suback, state) do
        {:cont, state}
      end

      @impl true
      def handle_unsuback(_unsubscribe, _unsuback, state) do
        {:cont, state}
      end

      @impl true
      def handle_disconnect(_disconnect, state) do
        {:ok, state}
      end

      defoverridable Tortoise.Handler
    end
  end

  @typedoc """
  Action to perform before reentering the execution loop.

  The supported next actions are:

    - Tell the connection process to subscribe to a topic filter
    - Tell the connection process to unsubscribe from a topic filter

  More next actions might be supported in the future.
  """
  @type next_action() ::
          {:subscribe, Tortoise.topic_filter(), [{:qos, Tortoise.qos()} | {:timeout, timeout()}]}
          | {:unsubscribe, Tortoise.topic_filter()}

  @doc """
  Invoked when the connection is started.

  `args` is the argument passed in from the connection configuration.

  Returning `{:ok, state}` will let the MQTT connection receive data
  from the MQTT broker, and the value contained in `state` will be
  used as the process state.
  """
  @callback init(args :: term()) :: {:ok, state}
            when state: any()

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
  @callback status_change(status, state :: term()) ::
              {:cont, new_state}
              | {:cont, new_state, [next_action()]}
            when status: :up | :down,
                 new_state: term()

  @callback handle_connack(connack, state :: term()) ::
              {:ok, new_state}
              | {:ok, new_state, [next_action()]}
              | {:error, reason :: term()}
            when connack: Package.Connack.t(),
                 new_state: term()

  @callback handle_suback(subscribe, suback, state :: term) :: {:ok, new_state}
            when subscribe: Package.Subscribe.t(),
                 suback: Package.Suback.t(),
                 new_state: term()

  @callback handle_unsuback(unsubscribe, unsuback, state :: term) :: {:ok, new_state}
            when unsubscribe: Package.Unsubscribe.t(),
                 unsuback: Package.Unsuback.t(),
                 new_state: term()

  @doc """
  Invoked when messages are published to subscribed topics.

  The `topic` comes in the form of a list of binaries, making it
  possible to pattern match on the topic levels of the retrieved
  publish, store the individual topic levels as variables and use it
  in the function body.

  `Payload` is a binary. MQTT 3.1.1 does not specify any format of the
  payload, so it has to be decoded and validated depending on the
  needs of the application.

  In an example where we are already subscribed to the topic filter
  `room/+/temp` and want to dispatch the received messages to a
  `Temperature` application we could set up our `handle_publish` as
  such:

      def handle_publish(["room", room, "temp"], publish, state) do
        :ok = Temperature.record(room, publish.payload)
        {:cont, state}
      end

  Notice; the `handle_publish/3`-callback run inside the connection
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
  @callback handle_publish(topic_levels, payload, state :: term()) ::
              {:cont, new_state}
              | {:cont, new_state, [next_action()]}
            when new_state: term(),
                 topic_levels: [String.t()],
                 payload: Tortoise.payload()

  @callback handle_puback(puback, state :: term()) :: {:ok, new_state}
            when puback: Package.Puback.t(),
                 new_state: term()

  @callback handle_pubrec(pubrec, state :: term()) :: {:ok, new_state}
            when pubrec: Package.Pubrec.t(),
                 new_state: term()

  @callback handle_pubrel(pubrel, state :: term()) :: {:ok, new_state}
            when pubrel: Package.Pubrel.t(),
                 new_state: term()

  @callback handle_pubcomp(pubcomp, state :: term()) :: {:ok, new_state}
            when pubcomp: Package.Pubcomp.t(),
                 new_state: term()

  @callback handle_disconnect(disconnect, state :: term()) :: {:ok, new_state}
            when source: :server | :network,
                 disconnect: {source, Package.Disconnect.t()},
                 new_state: term()

  # todo, should we do handle_pingresp as well ?

  @doc """
  Invoked when the connection process is about to exit.

  If anything is setup during the `init/1` callback it should get
  cleaned up during the `terminate/2` callback.
  """
  @callback terminate(reason, state :: term) :: ignored
            when reason: :normal | :shutdown | {:shutdown, term()},
                 ignored: term()

  @optional_callbacks status_change: 2,
                      handle_pubrec: 2,
                      handle_pubrel: 2,
                      handle_pubcomp: 2,
                      handle_puback: 2,
                      terminate: 2

  @doc false
  @spec execute_init(t) :: {:ok, t} | :ignore | {:stop, term()}
  def execute_init(handler) do
    handler.module
    |> apply(:init, [handler.initial_args])
    |> case do
      {:ok, initial_state} ->
        {:ok, %__MODULE__{handler | state: initial_state}}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  # todo, fix the type spec here so it contain the next actions and
  # error path as well
  @doc false
  @spec execute_status_change(t, status) :: {:ok, t}
        when status: :up | :down
  def execute_status_change(handler, status) do
    apply(handler.module, :status_change, [status, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec execute_handle_connack(t, Package.Connack.t()) ::
          {:ok, t} | {:error, {:invalid_next_action, term()}}
  def execute_handle_connack(handler, %Package.Connack{} = connack) do
    apply(handler.module, :handle_connack, [connack, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:stop, reason, updated_state} ->
        {:stop, reason, %__MODULE__{handler | state: updated_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec execute_handle_disconnect(t, disconnect) :: {:stop, term(), t}
        when disconnect: {:server, %Package.Disconnect{}} | {:network, atom()}
  def execute_handle_disconnect(handler, {source, _reason} = disconnect)
      when source in [:server, :network] do
    apply(handler.module, :handle_disconnect, [disconnect, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:stop, reason, updated_state} ->
        {:stop, reason, %__MODULE__{handler | state: updated_state}}
    end
  end

  @doc false
  @spec execute_terminate(t, reason) :: ignored
        when reason: term(),
             ignored: term()
  def execute_terminate(handler, reason) do
    _ignored = apply(handler.module, :terminate, [reason, handler.state])
  end

  @doc false
  @spec execute_handle_suback(t, Package.Subscribe.t(), Package.Suback.t()) :: {:ok, t}
  def execute_handle_suback(handler, subscribe, suback) do
    apply(handler.module, :handle_suback, [subscribe, suback, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec execute_handle_unsuback(t, Package.Unsubscribe.t(), Package.Unsuback.t()) ::
          {:ok, t, [any()]}
  def execute_handle_unsuback(handler, unsubscribe, unsuback) do
    apply(handler.module, :handle_unsuback, [unsubscribe, unsuback, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec execute_handle_publish(t, Package.Publish.t()) ::
          {:ok, t} | {:error, {:invalid_next_action, term()}}
  def execute_handle_publish(handler, %Package.Publish{qos: 0} = publish) do
    topic_list = String.split(publish.topic, "/")

    apply(handler.module, :handle_publish, [topic_list, publish, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute_handle_publish(handler, %Package.Publish{identifier: id, qos: 1} = publish) do
    topic_list = String.split(publish.topic, "/")

    apply(handler.module, :handle_publish, [topic_list, publish, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        puback = %Package.Puback{identifier: id}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, puback, updated_handler, next_actions}

      {{:cont, properties}, updated_state, next_actions} when is_list(properties) ->
        puback = %Package.Puback{identifier: id, properties: properties}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, puback, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute_handle_publish(handler, %Package.Publish{identifier: id, qos: 2} = publish) do
    topic_list = String.split(publish.topic, "/")

    apply(handler.module, :handle_publish, [topic_list, publish, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        pubrec = %Package.Pubrec{identifier: id}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubrec, updated_handler, next_actions}

      {{:cont, properties}, updated_state, next_actions} when is_list(properties) ->
        pubrec = %Package.Pubrec{identifier: id, properties: properties}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubrec, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # @spec execute_handle_puback(t, Package.Puback.t()) ::
  #         {:ok, t} | {:error, {:invalid_next_action, term()}}
  def execute_handle_puback(handler, %Package.Puback{} = puback) do
    apply(handler.module, :handle_puback, [puback, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # @spec execute_handle_pubrec(t, Package.Pubrec.t()) ::
  #         {:ok, t} | {:error, {:invalid_next_action, term()}}
  def execute_handle_pubrec(handler, %Package.Pubrec{identifier: id} = pubrec) do
    apply(handler.module, :handle_pubrec, [pubrec, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        pubrel = %Package.Pubrel{identifier: id}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubrel, updated_handler, next_actions}

      {{:cont, properties}, updated_state, next_actions} when is_list(properties) ->
        pubrel = %Package.Pubrel{identifier: id, properties: properties}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubrel, updated_handler, next_actions}

      {{:cont, %Package.Pubrel{identifier: ^id} = pubrel}, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubrel, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # @spec execute_handle_pubrel(t, Package.Pubrel.t()) ::
  #         {:ok, t} | {:error, {:invalid_next_action, term()}}
  def execute_handle_pubrel(handler, %Package.Pubrel{identifier: id} = pubrel) do
    apply(handler.module, :handle_pubrel, [pubrel, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        pubcomp = %Package.Pubcomp{identifier: id}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubcomp, updated_handler, next_actions}

      {{:cont, properties}, updated_state, next_actions} when is_list(properties) ->
        pubcomp = %Package.Pubcomp{identifier: id, properties: properties}
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubcomp, updated_handler, next_actions}

      {{:cont, %Package.Pubcomp{identifier: ^id} = pubcomp}, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, pubcomp, updated_handler, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # @spec execute_handle_pubcomp(t, Package.Pubcomp.t()) ::
  #         {:ok, t} | {:error, {:invalid_next_action, term()}}
  def execute_handle_pubcomp(handler, %Package.Pubcomp{} = pubcomp) do
    apply(handler.module, :handle_pubcomp, [pubcomp, handler.state])
    |> transform_result()
    |> case do
      {:cont, updated_state, next_actions} ->
        updated_handler = %__MODULE__{handler | state: updated_state}
        {:ok, updated_handler, next_actions}
    end
  end

  defp transform_result({:stop, reason, updated_state}) do
    {:stop, reason, updated_state}
  end

  defp transform_result({:error, reason}) do
    {:error, reason}
  end

  defp transform_result({cont, updated_state, next_actions}) when is_list(next_actions) do
    case Enum.split_with(next_actions, &valid_next_action?/1) do
      {_, []} ->
        # add option lists to next actions that do not have them yet,
        # this could probably be done in a smarter way; a function
        # that both validate and coerce the arguments in one pass
        coerced_next_actions =
          for action <- next_actions do
            case action do
              {:subscribe, topic} ->
                {:subscribe, topic, []}

              {:unsubscribe, topic} ->
                {:unsubscribe, topic, []}

              otherwise ->
                otherwise
            end
          end

        {cont, updated_state, coerced_next_actions}

      {_, invalid_next_actions} ->
        {:error, {:invalid_next_action, invalid_next_actions}}
    end
  end

  defp transform_result({cont, updated_state}) do
    transform_result({cont, updated_state, []})
  end

  # subscribe
  defp valid_next_action?({:subscribe, topic}), do: is_binary(topic)

  defp valid_next_action?({:subscribe, topic, opts}) do
    is_binary(topic) and is_list(opts)
  end

  # unsubscribe
  defp valid_next_action?({:unsubscribe, topic}), do: is_binary(topic)

  defp valid_next_action?({:unsubscribe, topic, opts}) do
    is_binary(topic) and is_list(opts)
  end

  # disconnect
  defp valid_next_action?(:disconnect), do: true

  defp valid_next_action?({:eval, fun}) when is_function(fun, 1), do: true

  defp valid_next_action?(_otherwise), do: false
end
