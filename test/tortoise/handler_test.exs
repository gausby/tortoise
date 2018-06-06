defmodule Tortoise.HandlerTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Handler

  alias Tortoise.Handler
  alias Tortoise.Connection.Inflight.Track
  alias Tortoise.Package

  defmodule TestHandler do
    @behaviour Handler

    def init(opts) do
      send(opts[:pid], :init)
      {:ok, opts}
    end

    def connection(status, state) do
      send(state[:pid], {:connection, status})
      {:ok, state}
    end

    def subscription(status, topic, state) do
      send(state[:pid], {:subscription, status, topic})
      {:ok, state}
    end

    def handle_message(topic, payload, state) do
      send(state[:pid], {:publish, topic, payload})
      {:ok, state}
    end

    def terminate(reason, state) do
      send(state[:pid], {:terminate, reason})
      :ok
    end
  end

  setup _context do
    handler = %Tortoise.Handler{module: TestHandler, initial_args: [pid: self()]}
    {:ok, %{handler: handler}}
  end

  defp set_state(%Handler{module: TestHandler} = handler, update) do
    %Handler{handler | state: update}
  end

  describe "execute init/1" do
    test "return ok-tuple", context do
      assert {:ok, %Handler{}} = Handler.execute(:init, context.handler)
      assert_receive :init
    end
  end

  describe "execute connection/2" do
    test "return ok-tuple", context do
      handler = set_state(context.handler, pid: self())
      assert {:ok, %Handler{}} = Handler.execute({:connection, :up}, handler)
      assert_receive {:connection, :up}

      assert {:ok, %Handler{}} = Handler.execute({:connection, :down}, handler)
      assert_receive {:connection, :down}
    end
  end

  describe "execute handle_message/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      payload = :crypto.strong_rand_bytes(5)
      topics = "foo/bar"
      publish = %Package.Publish{topic: topics, payload: payload}

      assert {:ok, %Handler{}} = Handler.execute({:publish, publish}, handler)
      # the topics will be in the form of a list making it possible to
      # pattern match on the topic levels
      assert_receive {:publish, topic_list, ^payload}
      assert is_list(topic_list)
      assert topics == Enum.join(topic_list, "/")
    end
  end

  describe "execute subscribe/2" do
    test "return ok", context do
      subscribe = %Package.Subscribe{identifier: 1, topics: [{"foo", 0}, {"bar", 1}, {"baz", 0}]}
      suback = %Package.Suback{identifier: 1, acks: [ok: 0, ok: 0, error: :access_denied]}
      caller = {self(), make_ref()}

      result =
        Track.create({:negative, caller}, subscribe)
        |> Track.update({:dispatched, subscribe})
        |> Track.update({:received, suback})

      handler = set_state(context.handler, pid: self())
      assert {:ok, %Handler{}} = Handler.execute({:subscribe, result}, handler)

      assert_receive {:subscription, :up, "foo"}
      assert_receive {:subscription, {:error, :access_denied}, "baz"}
      assert_receive {:subscription, {:warn, requested: 1, accepted: 0}, "bar"}
    end
  end

  describe "execute unsubscribe/2" do
    test "return ok", context do
      unsubscribe = %Package.Unsubscribe{identifier: 1, topics: ["foo/bar", "baz/quun"]}
      unsuback = %Package.Unsuback{identifier: 1}
      caller = {self(), make_ref()}

      result =
        Track.create({:negative, caller}, unsubscribe)
        |> Track.update({:dispatched, unsubscribe})
        |> Track.update({:received, unsuback})

      handler = set_state(context.handler, pid: self())
      assert {:ok, %Handler{}} = Handler.execute({:unsubscribe, result}, handler)
      # we should receive two subscription down messages
      assert_receive {:subscription, :down, "foo/bar"}
      assert_receive {:subscription, :down, "baz/quun"}
    end
  end

  describe "execute terminate/2" do
    test "return ok", context do
      handler = set_state(context.handler, pid: self())
      assert :ok = Handler.execute({:terminate, :normal}, handler)
      assert_receive {:terminate, :normal}
    end
  end
end
