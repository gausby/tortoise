defmodule Tortoise.HandlerTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Handler

  alias Tortoise.Handler
  alias Tortoise.Package

  defmodule TestHandler do
    @behaviour Handler

    def init(opts) do
      send(opts[:pid], :init)
      {:ok, opts}
    end

    def connection(status, state) do
      send(state[:pid], {:connection, status})

      case state[:connection] do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [status, state])
      end
    end

    def handle_connack(connack, state) do
      send(state[:pid], {:connack, connack})
      make_return(connack, state)
    end

    def handle_suback(subscribe, suback, state) do
      send(state[:pid], {:suback, {subscribe, suback}})
      {:cont, state}
    end

    def handle_unsuback(unsubscribe, unsuback, state) do
      send(state[:pid], {:unsuback, {unsubscribe, unsuback}})
      {:cont, state}
    end

    def handle_publish(topic, publish, state) do
      send(state[:pid], {:publish, topic, publish})
      make_return(publish, state)
    end

    def terminate(reason, state) do
      send(state[:pid], {:terminate, reason})
      :ok
    end

    def handle_puback(puback, state) do
      send(state[:pid], {:puback, puback})
      make_return(puback, state)
    end

    def handle_pubrec(pubrec, state) do
      send(state[:pid], {:pubrec, pubrec})
      make_return(pubrec, state)
    end

    def handle_pubrel(pubrel, state) do
      send(state[:pid], {:pubrel, pubrel})
      make_return(pubrel, state)
    end

    def handle_pubcomp(pubcomp, state) do
      send(state[:pid], {:pubcomp, pubcomp})
      make_return(pubcomp, state)
    end

    def handle_disconnect(disconnect, state) do
      send(state[:pid], {:disconnect, disconnect})
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
      Package.Publish => :publish,
      Package.Puback => :puback,
      Package.Pubrec => :pubrec,
      Package.Pubrel => :pubrel,
      Package.Pubcomp => :pubcomp,
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

    defp make_return(%type{}, _) do
      raise ArgumentError, message: "Unknown type for #{__MODULE__}: #{type}"
    end
  end

  setup _context do
    handler = %Tortoise.Handler{module: TestHandler, initial_args: [pid: self()]}
    {:ok, %{handler: handler}}
  end

  defp set_state(%Handler{module: TestHandler} = handler, update) do
    %Handler{handler | state: update}
  end

  describe "execute_init/1" do
    test "return ok-tuple", context do
      assert {:ok, %Handler{}} = Handler.execute_init(context.handler)
      assert_receive :init
    end
  end

  describe "execute connection/2" do
    test "return continues", context do
      handler = set_state(context.handler, pid: self())
      assert {:ok, %Handler{}, []} = Handler.execute_connection(handler, :up)
      assert_receive {:connection, :up}

      assert {:ok, %Handler{}, []} = Handler.execute_connection(handler, :down)
      assert_receive {:connection, :down}
    end

    test "return continue with next actions", context do
      next_actions = [{:subscribe, "foo/bar", qos: 0}]
      connection_fn = fn _status, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, pid: self(), connection: connection_fn)

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
      handler = set_state(context.handler, pid: self(), connack: connack_fn)

      assert {:ok, %Handler{} = state, []} = Handler.execute_handle_connack(handler, connack)

      assert_receive {:connack, ^connack}
    end

    test "return continue with next actions", context do
      connack = %Package.Connack{
        reason: :success,
        session_present: false
      }

      next_actions = [{:subscribe, "foo/bar", [qos: 0]}]
      connack_fn = fn ^connack, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, pid: self(), connack: connack_fn)

      assert {:ok, %Handler{} = state, ^next_actions} =
               Handler.execute_handle_connack(handler, connack)

      assert_receive {:connack, ^connack}
    end
  end

  describe "execute handle_publish/2" do
    test "return ok-2", context do
      handler = set_state(context.handler, pid: self())
      payload = :crypto.strong_rand_bytes(5)
      topic = "foo/bar"
      publish = %Package.Publish{topic: topic, payload: payload}

      assert {:ok, %Handler{}, []} = Handler.execute_handle_publish(handler, publish)
      # the topic will be in the form of a list making it possible to
      # pattern match on the topic levels
      assert_receive {:publish, topic_list, ^publish}
      assert is_list(topic_list)
      assert topic == Enum.join(topic_list, "/")
    end

    test "return ok-3", context do
      next_actions = [{:subscribe, "foo/bar", [qos: 0]}]
      publish_fn = fn %Package.Publish{}, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, pid: self(), publish: publish_fn)
      payload = :crypto.strong_rand_bytes(5)
      topic = "foo/bar"
      publish = %Package.Publish{topic: topic, payload: payload}

      assert {:ok, %Handler{}, ^next_actions} = Handler.execute_handle_publish(handler, publish)

      # the topic will be in the form of a list making it possible to
      # pattern match on the topic levels
      assert_receive {:publish, topic_list, ^publish}
      assert is_list(topic_list)
      assert topic == Enum.join(topic_list, "/")
    end

    test "return ok-3 with invalid next action", context do
      next_actions = [{:unsubscribe, "foo/bar"}, {:invalid, "bar"}]
      publish_fn = fn %Package.Publish{}, state -> {:cont, state, next_actions} end
      handler = set_state(context.handler, pid: self(), publish: publish_fn)
      payload = :crypto.strong_rand_bytes(5)
      topic = "foo/bar"
      publish = %Package.Publish{topic: topic, payload: payload}

      assert {:error, {:invalid_next_action, [{:invalid, "bar"}]}} =
               Handler.execute_handle_publish(handler, publish)

      # the callback is still run so lets check the received data
      assert_receive {:publish, topic_list, ^publish}
      assert is_list(topic_list)
      assert topic == Enum.join(topic_list, "/")
    end
  end

  describe "execute handle_suback/3" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())

      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo", qos: 0}]
      }

      suback = %Package.Suback{identifier: 1, acks: [ok: 0]}

      assert {:ok, %Handler{} = state, []} =
               Handler.execute_handle_suback(handler, subscribe, suback)

      assert_receive {:suback, {^subscribe, ^suback}}
    end
  end

  describe "execute handle_unsuback/3" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())

      unsubscribe = %Package.Unsubscribe{
        identifier: 1,
        topics: ["foo"]
      }

      unsuback = %Package.Unsuback{identifier: 1, results: [:success]}

      assert {:ok, %Handler{} = state, []} =
               Handler.execute_handle_unsuback(handler, unsubscribe, unsuback)

      assert_receive {:unsuback, {^unsubscribe, ^unsuback}}
    end
  end

  describe "execute terminate/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      assert :ok = Handler.execute_terminate(handler, :normal)
      assert_receive {:terminate, :normal}
    end
  end

  describe "execute handle_puback/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      puback = %Package.Puback{identifier: 1}

      assert {:ok, %Handler{} = state, []} =
               handler
               |> Handler.execute_handle_puback(puback)

      assert_receive {:puback, ^puback}
    end
  end

  # callbacks for the QoS=2 message exchange
  describe "execute handle_pubrec/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      pubrec = %Package.Pubrec{identifier: 1}

      assert {:ok, %Package.Pubrel{identifier: 1}, %Handler{}, []} =
               handler
               |> Handler.execute_handle_pubrec(pubrec)

      assert_receive {:pubrec, ^pubrec}
    end

    test "return ok with custom pubrel", context do
      pubrec = %Package.Pubrec{identifier: 1}
      properties = [{"foo", "bar"}]

      pubrec_fn = fn ^pubrec, state ->
        {{:cont, %Package.Pubrel{identifier: 1, properties: properties}}, state}
      end

      handler = set_state(context.handler, pid: self(), pubrec: pubrec_fn)

      assert {:ok, %Package.Pubrel{identifier: 1, properties: ^properties}, %Handler{}, []} =
               Handler.execute_handle_pubrec(handler, pubrec)

      assert_receive {:pubrec, ^pubrec}
    end

    test "raise an error if a custom pubrel with the wrong id is returned", context do
      pubrec = %Package.Pubrec{identifier: 1}

      pubrec_fn = fn %Package.Pubrec{identifier: id}, state ->
        {{:cont, %Package.Pubrel{identifier: id + 1}}, state}
      end

      handler = set_state(context.handler, pid: self(), pubrec: pubrec_fn)

      assert_raise CaseClauseError, fn ->
        Handler.execute_handle_pubrec(handler, pubrec)
      end

      assert_receive {:pubrec, ^pubrec}
    end

    test "returning {:cont, [{string(), string()}]} should result in a pubrel with properties",
         context do
      pubrec = %Package.Pubrec{identifier: 1}
      properties = [{"foo", "bar"}]
      pubrec_fn = fn ^pubrec, state -> {{:cont, properties}, state} end
      handler = set_state(context.handler, pid: self(), pubrec: pubrec_fn)

      assert {:ok, %Package.Pubrel{identifier: 1, properties: ^properties}, %Handler{}, []} =
               Handler.execute_handle_pubrec(handler, pubrec)

      assert_receive {:pubrec, ^pubrec}
    end
  end

  describe "execute handle_pubrel/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      pubrel = %Package.Pubrel{identifier: 1}

      assert {:ok, %Package.Pubcomp{identifier: 1}, %Handler{} = state, []} =
               Handler.execute_handle_pubrel(handler, pubrel)

      assert_receive {:pubrel, ^pubrel}
    end

    test "return ok with custom pubrel", context do
      properties = [{"foo", "bar"}]

      pubrel_fn = fn %Package.Pubrel{identifier: 1}, state ->
        {{:cont, %Package.Pubcomp{identifier: 1, properties: properties}}, state}
      end

      handler = set_state(context.handler, pid: self(), pubrel: pubrel_fn)
      pubrel = %Package.Pubrel{identifier: 1}

      assert {:ok, %Package.Pubcomp{identifier: 1, properties: ^properties}, %Handler{} = state,
              []} = Handler.execute_handle_pubrel(handler, pubrel)

      assert_receive {:pubrel, ^pubrel}
    end

    test "should not allow custom Pubrel with a different id", context do
      pubrel_fn = fn %Package.Pubrel{identifier: id}, state ->
        {{:cont, %Package.Pubcomp{identifier: id + 1}}, state}
      end

      handler = set_state(context.handler, pid: self(), pubrel: pubrel_fn)
      pubrel = %Package.Pubrel{identifier: 1}

      # todo, consider making an IdentifierMismatchError type
      assert_raise CaseClauseError, fn ->
        Handler.execute_handle_pubrel(handler, pubrel)
      end

      assert_receive {:pubrel, ^pubrel}
    end

    test "returning {:cont, [{string(), string()}]} become user defined properties", context do
      properties = [{"foo", "bar"}, {"bar", "baz"}]

      pubrel_fn = fn %Package.Pubrel{identifier: 1}, state ->
        {{:cont, properties}, state}
      end

      handler = set_state(context.handler, pid: self(), pubrel: pubrel_fn)
      pubrel = %Package.Pubrel{identifier: 1}

      assert {:ok, %Package.Pubcomp{identifier: 1, properties: ^properties}, %Handler{} = state,
              []} = Handler.execute_handle_pubrel(handler, pubrel)

      assert_receive {:pubrel, ^pubrel}
    end
  end

  describe "execute handle_pubcomp/2" do
    test "return ok", context do
      pubcomp = %Package.Pubcomp{identifier: 1}

      pubcomp_fn = fn ^pubcomp, state ->
        {:cont, state}
      end

      handler = set_state(context.handler, pid: self(), pubcomp: pubcomp_fn)

      assert {:ok, %Handler{} = state, []} =
               handler
               |> Handler.execute_handle_pubcomp(pubcomp)

      assert_receive {:pubcomp, ^pubcomp}
    end

    test "return ok with next actions", context do
      pubcomp = %Package.Pubcomp{identifier: 1}
      next_actions = [{:subscribe, "foo/bar", qos: 0}]

      pubcomp_fn = fn ^pubcomp, state ->
        {:cont, state, next_actions}
      end

      handler = set_state(context.handler, pid: self(), pubcomp: pubcomp_fn)

      assert {:ok, %Handler{} = state, ^next_actions} =
               Handler.execute_handle_pubcomp(handler, pubcomp)

      assert_receive {:pubcomp, ^pubcomp}
    end
  end

  describe "execute handle_disconnect/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      disconnect = %Package.Disconnect{}

      assert {:ok, %Handler{} = state, []} =
               handler
               |> Handler.execute_handle_disconnect(disconnect)

      assert_receive {:disconnect, ^disconnect}
    end
  end
end
