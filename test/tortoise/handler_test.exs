defmodule Tortoise.HandlerTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Handler

  alias Tortoise.Handler
  alias Tortoise.Package

  defmodule TestHandler do
    @moduledoc """
    A Tortoise callback handler for testing the input given and the
    returned output.

    This callback handler rely on having a keyword list as the state;
    when a callback is called it will look for an entry relating to
    that callback, and if an anonymous function is found it will be
    used as the return value. For instance, if the `handle_pubrel/2`
    callback is called, if will look for the `pubrel` in the state
    keyword list; if the value is nil an `{:cont, state}` will get
    returned, if an anonymous function of arity two is found it will
    get called with `apply(fun, [pubrel, state])`. This makes it
    possible to pass in a known state and set expectations in our
    tests.
    """

    @behaviour Handler

    # For these tests, if the initial_arg is a two-tuple of a function
    # and a term we will execute the function with the term as an
    # argument and use the return value as the return; otherwise we
    # will just return `{:ok, initial_arg}`
    def init({fun, opts}) when is_function(fun, 1), do: apply(fun, [opts])
    def init(opts), do: {:ok, opts}

    def terminate(reason, state) do
      case Keyword.get(state, :terminate) do
        nil ->
          :ok

        fun when is_function(fun, 2) ->
          apply(fun, [reason, state])

        fun when is_function(fun) ->
          msg = "Callback function for terminate in #{__MODULE__} should be of arity-two"
          raise ArgumentError, message: msg
      end
    end

    def connection(status, state) do
      case state[:connection] do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [status, state])
      end
    end

    def handle_publish(topic_list, publish, state) do
      case Keyword.get(state, :publish) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 3) ->
          apply(fun, [topic_list, publish, state])

        fun when is_function(fun) ->
          msg = "Callback function for Publish in #{__MODULE__} should be of arity-three"
          raise ArgumentError, message: msg
      end
    end

    def handle_connack(connack, state) do
      make_return(connack, state)
    end

    def handle_suback(subscribe, suback, state) do
      make_return({subscribe, suback}, state)
    end

    def handle_unsuback(unsubscribe, unsuback, state) do
      make_return({unsubscribe, unsuback}, state)
    end

    def handle_puback(puback, state) do
      make_return(puback, state)
    end

    def handle_pubrec(pubrec, state) do
      make_return(pubrec, state)
    end

    def handle_pubrel(pubrel, state) do
      make_return(pubrel, state)
    end

    def handle_pubcomp(pubcomp, state) do
      make_return(pubcomp, state)
    end

    def handle_disconnect(disconnect, state) do
      make_return(disconnect, state)
    end

    # `make return` will search the test handler state for a function
    # with an arity of two that relate to the given package, and if
    # found it will execute that function with the input package as
    # the first argument and the handler state as the second. This
    # allow us to specify the return value in the test itself, and
    # thereby testing everything the user would return in the
    # callbacks. If no callback function is defined we will default to
    # returning `{:cont, state}`.
    @package_to_type %{
      Package.Connack => :connack,
      Package.Puback => :puback,
      Package.Pubrec => :pubrec,
      Package.Pubrel => :pubrel,
      Package.Pubcomp => :pubcomp,
      Package.Suback => :suback,
      Package.Unsuback => :unsuback,
      Package.Disconnect => :disconnect
    }

    @allowed_package_types Map.keys(@package_to_type)

    defp make_return(%type{} = package, state) when type in @allowed_package_types do
      type = @package_to_type[type]

      case Keyword.get(state, type) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [package, state])

        fun when is_function(fun) ->
          msg = "Callback function for #{type} in #{__MODULE__} should be of arity-two"
          raise ArgumentError, message: msg
      end
    end

    defp make_return({package, %type{} = ack}, state) when type in @allowed_package_types do
      type = @package_to_type[type]

      case Keyword.get(state, type) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 3) ->
          apply(fun, [package, ack, state])

        fun when is_function(fun) ->
          msg = "Callback function for #{type} in #{__MODULE__} should be of arity-three"
          raise ArgumentError, message: msg
      end
    end

    defp make_return(%type{}, _) do
      raise ArgumentError, message: "Unknown type for #{__MODULE__}: #{type}"
    end
  end

  setup _context do
    handler = %Tortoise.Handler{module: TestHandler, initial_args: nil}
    {:ok, %{handler: handler}}
  end

  defp set_state(%Handler{module: TestHandler} = handler, update) do
    %Handler{handler | state: update}
  end

  describe "execute_init/1" do
    test "return ok-tuple should set the handler state" do
      handler = %Handler{module: TestHandler, state: nil, initial_args: make_ref()}
      assert {:ok, %Handler{state: state, initial_args: state}} = Handler.execute_init(handler)
    end

    test "returning ignore" do
      init_fn = fn nil -> :ignore end
      handler = %Handler{module: TestHandler, state: nil, initial_args: {init_fn, nil}}
      assert :ignore = Handler.execute_init(handler)
    end

    test "returning stop with a reason" do
      reason = make_ref()
      init_fn = fn nil -> {:stop, reason} end
      handler = %Handler{module: TestHandler, state: nil, initial_args: {init_fn, nil}}
      assert {:stop, ^reason} = Handler.execute_init(handler)
    end
  end

  describe "execute connection/2" do
    test "return continues", context do
      parent = self()

      connection_fn = fn status, state ->
        send(parent, {:connection, status})
        {:cont, state}
      end

      handler = set_state(context.handler, connection: connection_fn)
      assert {:ok, %Handler{}, []} = Handler.execute_connection(handler, :up)
      assert_receive {:connection, :up}

      assert {:ok, %Handler{}, []} = Handler.execute_connection(handler, :down)
      assert_receive {:connection, :down}
    end

    test "return continue with next actions", context do
      next_actions = [{:subscribe, "foo/bar", qos: 0}]
      parent = self()

      connection_fn = fn status, state ->
        send(parent, {:connection, status})
        {:cont, state, next_actions}
      end

      handler = set_state(context.handler, connection: connection_fn)

      assert {:ok, %Handler{}, ^next_actions} = Handler.execute_connection(handler, :up)

      assert_receive {:connection, :up}

      assert {:ok, %Handler{}, ^next_actions} = Handler.execute_connection(handler, :down)

      assert_receive {:connection, :down}
    end
  end

  describe "execute handle_connack/2" do
    test "return continue", context do
      connack = %Package.Connack{
        reason: :success,
        session_present: false
      }

      connack_fn = fn ^connack, state -> {:cont, state} end
      handler = set_state(context.handler, connack: connack_fn)

      assert {:ok, %Handler{} = state, []} = Handler.execute_handle_connack(handler, connack)
    end

    test "return continue with next actions", context do
      connack = %Package.Connack{
        reason: :success,
        session_present: false
      }

      next_actions = [{:subscribe, "foo/bar", [qos: 0]}]
      connack_fn = fn ^connack, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, connack: connack_fn)

      assert {:ok, %Handler{} = state, ^next_actions} =
               Handler.execute_handle_connack(handler, connack)
    end
  end

  describe "execute handle_publish/2" do
    test "return continue", context do
      payload = :crypto.strong_rand_bytes(5)
      topic = "foo/bar"
      publish = %Package.Publish{topic: topic, payload: payload}
      parent = self()

      publish_fn = fn topic_list, ^publish, state ->
        send(parent, {:received_topic_list, topic_list})
        {:cont, state}
      end

      handler = set_state(context.handler, publish: publish_fn)

      assert {:ok, %Handler{}, []} = Handler.execute_handle_publish(handler, publish)
      # the topic will be in the form of a list making it possible to
      # pattern match on the topic levels
      assert_receive {:received_topic_list, topic_list}
      assert is_list(topic_list)
      assert topic == Enum.join(topic_list, "/")
    end

    test "return continue with next actions", context do
      topic = "foo/bar"
      payload = :crypto.strong_rand_bytes(5)
      next_actions = [{:subscribe, "foo/bar", [qos: 0]}]
      publish = %Package.Publish{topic: topic, payload: payload}
      publish_fn = fn _topic_list, ^publish, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, publish: publish_fn)
      assert {:ok, %Handler{}, ^next_actions} = Handler.execute_handle_publish(handler, publish)
    end

    test "return continue with invalid next action", context do
      topic = "foo/bar"
      payload = :crypto.strong_rand_bytes(5)
      publish = %Package.Publish{topic: topic, payload: payload}
      next_actions = [{:unsubscribe, "foo/bar"}, {:invalid, "bar"}]
      publish_fn = fn _topic_list, ^publish, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, publish: publish_fn)

      assert {:error, {:invalid_next_action, [{:invalid, "bar"}]}} =
               Handler.execute_handle_publish(handler, publish)
    end
  end

  describe "execute handle_suback/3" do
    test "return continue", context do
      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo", qos: 0}]
      }

      suback = %Package.Suback{identifier: 1, acks: [ok: 0]}

      suback_fn = fn ^subscribe, ^suback, state -> {:cont, state} end
      handler = set_state(context.handler, suback: suback_fn)

      assert {:ok, %Handler{} = state, []} =
               Handler.execute_handle_suback(handler, subscribe, suback)
    end

    test "return continue with next actions", context do
      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo", qos: 0}]
      }

      suback = %Package.Suback{identifier: 1, acks: [ok: 0]}

      next_actions = [{:unsubscribe, "foo/bar"}]

      suback_fn = fn ^subscribe, ^suback, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, suback: suback_fn)

      assert {:ok, %Handler{} = state, [{:unsubscribe, "foo/bar", []}]} =
               Handler.execute_handle_suback(handler, subscribe, suback)
    end
  end

  describe "execute handle_unsuback/3" do
    test "return continue", context do
      unsubscribe = %Package.Unsubscribe{identifier: 1, topics: ["foo"]}
      unsuback = %Package.Unsuback{identifier: 1, results: [:success]}
      unsuback_fn = fn ^unsubscribe, ^unsuback, state -> {:cont, state} end
      handler = set_state(context.handler, unsuback: unsuback_fn)

      assert {:ok, %Handler{} = state, []} =
               Handler.execute_handle_unsuback(handler, unsubscribe, unsuback)
    end

    test "return continue with next actions", context do
      unsubscribe = %Package.Unsubscribe{identifier: 1, topics: ["foo"]}
      unsuback = %Package.Unsuback{identifier: 1, results: [:success]}
      next_actions = [{:unsubscribe, "foo/bar"}]
      unsuback_fn = fn ^unsubscribe, ^unsuback, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, unsuback: unsuback_fn)

      assert {:ok, %Handler{} = state, [{:unsubscribe, "foo/bar", []}]} =
               Handler.execute_handle_unsuback(handler, unsubscribe, unsuback)
    end
  end

  # callbacks for the QoS=1 message exchange
  describe "execute handle_puback/2" do
    test "return continue", context do
      puback = %Package.Puback{identifier: 1}
      puback_fn = fn ^puback, state -> {:cont, state} end
      handler = set_state(context.handler, puback: puback_fn)

      assert {:ok, %Handler{} = state, []} = Handler.execute_handle_puback(handler, puback)
    end

    test "return continue with next actions", context do
      puback = %Package.Puback{identifier: 1}
      next_actions = [{:subscribe, "foo/bar", qos: 0}]
      puback_fn = fn ^puback, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, puback: puback_fn)

      assert {:ok, %Handler{} = state, ^next_actions} =
               Handler.execute_handle_puback(handler, puback)
    end
  end

  # callbacks for the QoS=2 message exchange
  describe "execute handle_pubrec/2" do
    test "return continue", context do
      pubrec = %Package.Pubrec{identifier: 1}
      pubrec_fn = fn ^pubrec, state -> {:cont, state} end
      handler = set_state(context.handler, pubrec: pubrec_fn)

      assert {:ok, %Package.Pubrel{identifier: 1}, %Handler{}, []} =
               Handler.execute_handle_pubrec(handler, pubrec)
    end

    test "return continue with custom pubrel", context do
      pubrec = %Package.Pubrec{identifier: 1}
      properties = [{"foo", "bar"}]

      pubrec_fn = fn ^pubrec, state ->
        {{:cont, %Package.Pubrel{identifier: 1, properties: properties}}, state}
      end

      handler = set_state(context.handler, pubrec: pubrec_fn)

      assert {:ok, %Package.Pubrel{identifier: 1, properties: ^properties}, %Handler{}, []} =
               Handler.execute_handle_pubrec(handler, pubrec)
    end

    test "raise an error if a custom pubrel with the wrong id is returned", context do
      pubrec = %Package.Pubrec{identifier: 1}

      pubrec_fn = fn %Package.Pubrec{identifier: id}, state ->
        {{:cont, %Package.Pubrel{identifier: id + 1}}, state}
      end

      handler = set_state(context.handler, pubrec: pubrec_fn)

      assert_raise CaseClauseError, fn ->
        Handler.execute_handle_pubrec(handler, pubrec)
      end
    end

    test "returning continue with a list should result in a pubrel with user props", context do
      pubrec = %Package.Pubrec{identifier: 1}
      properties = [{"foo", "bar"}]
      pubrec_fn = fn ^pubrec, state -> {{:cont, properties}, state} end
      handler = set_state(context.handler, pubrec: pubrec_fn)

      assert {:ok, %Package.Pubrel{identifier: 1, properties: ^properties}, %Handler{}, []} =
               Handler.execute_handle_pubrec(handler, pubrec)
    end
  end

  describe "execute handle_pubrel/2" do
    test "return continue", context do
      pubrel = %Package.Pubrel{identifier: 1}
      pubrel_fn = fn ^pubrel, state -> {:cont, state} end
      handler = set_state(context.handler, pubrel: pubrel_fn)

      assert {:ok, %Package.Pubcomp{identifier: 1}, %Handler{} = state, []} =
               Handler.execute_handle_pubrel(handler, pubrel)
    end

    test "return continue with custom pubcomp", context do
      pubrel = %Package.Pubrel{identifier: 1}
      properties = [{"foo", "bar"}]

      pubrel_fn = fn %Package.Pubrel{identifier: 1}, state ->
        {{:cont, %Package.Pubcomp{identifier: 1, properties: properties}}, state}
      end

      handler = set_state(context.handler, pubrel: pubrel_fn)

      assert {:ok, %Package.Pubcomp{identifier: 1, properties: ^properties}, %Handler{} = state,
              []} = Handler.execute_handle_pubrel(handler, pubrel)
    end

    test "should not allow custom pubcomp with a different id", context do
      pubrel = %Package.Pubrel{identifier: 1}

      pubrel_fn = fn %Package.Pubrel{identifier: id}, state ->
        {{:cont, %Package.Pubcomp{identifier: id + 1}}, state}
      end

      handler = set_state(context.handler, pubrel: pubrel_fn)

      # todo, consider making an IdentifierMismatchError type
      assert_raise CaseClauseError, fn ->
        Handler.execute_handle_pubrel(handler, pubrel)
      end
    end

    test "returning {:cont, [{string(), string()}]} become user defined properties", context do
      properties = [{"foo", "bar"}, {"bar", "baz"}]
      pubrel = %Package.Pubrel{identifier: 1}

      pubrel_fn = fn ^pubrel, state ->
        {{:cont, properties}, state}
      end

      handler = set_state(context.handler, pubrel: pubrel_fn)

      assert {:ok, %Package.Pubcomp{identifier: 1, properties: ^properties}, %Handler{} = state,
              []} = Handler.execute_handle_pubrel(handler, pubrel)
    end
  end

  describe "execute handle_pubcomp/2" do
    test "return continue", context do
      pubcomp = %Package.Pubcomp{identifier: 1}
      pubcomp_fn = fn ^pubcomp, state -> {:cont, state} end
      handler = set_state(context.handler, pubcomp: pubcomp_fn)

      assert {:ok, %Handler{} = state, []} =
               handler
               |> Handler.execute_handle_pubcomp(pubcomp)
    end

    test "return continue with next actions", context do
      pubcomp = %Package.Pubcomp{identifier: 1}
      next_actions = [{:subscribe, "foo/bar", qos: 0}]
      pubcomp_fn = fn ^pubcomp, state -> {:cont, state, next_actions} end

      handler = set_state(context.handler, pubcomp: pubcomp_fn)

      assert {:ok, %Handler{} = state, ^next_actions} =
               Handler.execute_handle_pubcomp(handler, pubcomp)
    end
  end

  describe "execute handle_disconnect/2" do
    test "return continue", context do
      disconnect = %Package.Disconnect{}
      disconnect_fn = fn ^disconnect, state -> {:cont, state} end
      handler = set_state(context.handler, disconnect: disconnect_fn)

      assert {:ok, %Handler{} = state, []} =
               Handler.execute_handle_disconnect(handler, disconnect)
    end

    test "return continue with next actions", context do
      disconnect = %Package.Disconnect{}
      next_actions = [{:subscribe, "foo/bar", qos: 2}]
      disconnect_fn = fn ^disconnect, state -> {:cont, state, next_actions} end

      handler = set_state(context.handler, disconnect: disconnect_fn)

      assert {:ok, %Handler{} = state, ^next_actions} =
               Handler.execute_handle_disconnect(handler, disconnect)
    end

    test "return stop with normal reason", context do
      disconnect = %Package.Disconnect{}
      disconnect_fn = fn ^disconnect, state -> {:stop, :normal, state} end
      handler = set_state(context.handler, disconnect: disconnect_fn)

      assert {:stop, :normal, %Handler{} = state} =
               Handler.execute_handle_disconnect(handler, disconnect)
    end
  end

  describe "execute terminate/2" do
    test "return ok", context do
      parent = self()

      terminate_fn = fn reason, _state ->
        send(parent, {:terminate, reason})
        :ok
      end

      handler = set_state(context.handler, terminate: terminate_fn)
      assert :ok = Handler.execute_terminate(handler, :normal)
      assert_receive {:terminate, :normal}
    end
  end
end
