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

    def connection(status, %{next_actions: next_actions} = state) do
      send(state[:pid], {:connection, status})
      {:cont, state, next_actions}
    end

    def connection(status, state) do
      send(state[:pid], {:connection, status})
      {:cont, state}
    end

    def handle_connack(connack, state) do
      send(state[:pid], {:connack, connack})
      {:cont, state}
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

      case Keyword.get(state, :publish) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [publish, state])
      end
    end

    def terminate(reason, state) do
      send(state[:pid], {:terminate, reason})
      :ok
    end

    def handle_puback(puback, state) do
      send(state[:pid], {:puback, puback})

      case Keyword.get(state, :puback) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [puback, state])
      end
    end

    def handle_pubrec(pubrec, state) do
      send(state[:pid], {:pubrec, pubrec})

      case Keyword.get(state, :pubrec) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [pubrec, state])
      end
    end

    def handle_pubrel(pubrel, state) do
      send(state[:pid], {:pubrel, pubrel})

      case Keyword.get(state, :pubrel) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [pubrel, state])
      end
    end

    def handle_pubcomp(pubcomp, state) do
      send(state[:pid], {:pubcomp, pubcomp})

      case Keyword.get(state, :pubcomp) do
        nil ->
          {:cont, state}

        fun when is_function(fun, 2) ->
          apply(fun, [pubcomp, state])
      end
    end

    def handle_disconnect(disconnect, state) do
      send(state[:pid], {:disconnect, disconnect})
      {:cont, state}
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
    test "return ok-tuple", context do
      handler = set_state(context.handler, %{pid: self()})
      assert {:ok, %Handler{}, []} = Handler.execute_connection(handler, :up)
      assert_receive {:connection, :up}

      assert {:ok, %Handler{}, []} = Handler.execute_connection(handler, :down)
      assert_receive {:connection, :down}
    end

    test "return ok-3-tuple", context do
      next_actions = [{:subscribe, "foo/bar", qos: 0}]

      handler =
        context.handler
        |> set_state(%{pid: self(), next_actions: next_actions})

      assert {:ok, %Handler{}, ^next_actions} = Handler.execute_connection(handler, :up)

      assert_receive {:connection, :up}

      assert {:ok, %Handler{}, ^next_actions} = Handler.execute_connection(handler, :down)

      assert_receive {:connection, :down}
    end
  end

  describe "execute handle_connack/2" do
    test "return ok-tuple", context do
      handler = set_state(context.handler, pid: self())

      connack = %Package.Connack{
        reason: :success,
        session_present: false
      }

      assert {:ok, %Handler{} = state, []} = Handler.execute_handle_connack(handler, connack)

      assert_receive {:connack, ^connack}
    end
  end

  describe "execute handle_publish/2" do
    test "return ok-2", context do
      handler = set_state(context.handler, [pid: self()])
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
      publish_fn = fn (%Package.Publish{}, state) -> {:cont, state, next_actions} end
      handler = set_state(context.handler, [pid: self(), publish: publish_fn])
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
      handler = set_state(context.handler, [pid: self(), publish: publish_fn])
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
  end

  describe "execute handle_pubrel/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      pubrel = %Package.Pubrel{identifier: 1}

      assert {:ok, %Package.Pubcomp{identifier: 1}, %Handler{} = state, []} =
               Handler.execute_handle_pubrel(handler, pubrel)

      assert_receive {:pubrel, ^pubrel}
    end

    test "return ok with next_actions", context do
      pubrel_fn = fn %Package.Pubrel{identifier: 1}, state ->
        {{:cont, %Package.Pubcomp{identifier: 1, properties: [{"foo", "bar"}]}}, state}
      end

      handler = set_state(context.handler, pid: self(), pubrel: pubrel_fn)
      pubrel = %Package.Pubrel{identifier: 1}

      assert {:ok, %Package.Pubcomp{identifier: 1}, %Handler{} = state, []} =
               Handler.execute_handle_pubrel(handler, pubrel)

      assert_receive {:pubrel, ^pubrel}
    end
  end

  describe "execute handle_pubcomp/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      pubcomp = %Package.Pubcomp{identifier: 1}

      assert {:ok, %Handler{} = state, []} =
               handler
               |> Handler.execute_handle_pubcomp(pubcomp)

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
