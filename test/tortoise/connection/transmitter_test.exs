defmodule Tortoise.Connection.TransmitterTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Transmitter

  alias Tortoise.Connection.Transmitter
  alias Tortoise.{Package, Pipe}

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_transmitter(context) do
    opts = [client_id: context.client_id]
    {:ok, pid} = Transmitter.start_link(opts)
    {:ok, %{transmitter_pid: pid}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
    :ok = Transmitter.handle_socket(context.test, client_socket)
    {:ok, %{client: client_socket, server: server_socket}}
  end

  # update the context during a test run
  def run_setup(context, setup) when is_atom(setup) do
    context_update =
      case apply(__MODULE__, setup, [context]) do
        {:ok, update} -> update
        [{_, _} | _] = update -> update
        %{} = update -> update
      end

    Enum.into(context_update, context)
  end

  test "life-cycle", context do
    assert {:ok, pid} = Transmitter.start_link(client_id: context.client_id)
    assert Process.alive?(pid)
    assert :ok = Transmitter.stop(pid)
    refute Process.alive?(pid)
  end

  describe "subscribe/1" do
    setup [:setup_transmitter]

    test "subscribe while offline", context do
      client_id = context.client_id
      assert :ok = Transmitter.subscribe(client_id)
      assert Transmitter.subscribers(client_id) == [self()]
      # when we get a connection the subscribers should get a socket
      _context = run_setup(context, :setup_connection)
      assert_receive {Tortoise, {:transmitter, %Pipe{socket: socket}}}
      assert is_port(socket)
    end

    test "subscribe while online", context do
      client_id = context.client_id
      _context = run_setup(context, :setup_connection)
      assert :ok = Transmitter.subscribe(client_id)
      assert Transmitter.subscribers(client_id) == [self()]
      # The Transmitter should send the socket to the subscriber
      assert_receive {Tortoise, {:transmitter, %Pipe{socket: socket}}}
      assert is_port(socket)
    end

    test "remove subscription when the subscriber terminates", context do
      client_id = context.client_id
      # First create a subscription, for this test we will terminate
      # the subscriber, so we need it to run in another process. To be
      # able to control the timing we will need to send messages
      # between the test process and the process that own the
      # subscription; so we will use receive/1 and send/2 in this test
      # for that purpose.
      parent = self()

      subscriber =
        spawn_link(fn ->
          :ok = Transmitter.subscribe(client_id)
          # tell the parent that it can assert on the subscription
          send(parent, {:subscribed, self()})

          # keep the process alive until the parent tell it to release
          receive do
            :release ->
              send(parent, {:released, self()})
              :ok
              # The subscriber will now terminate and the transmitter
              # should remove it from its subscriber-list
          end
        end)

      assert_receive {:subscribed, ^subscriber}
      assert Transmitter.subscribers(client_id) == [subscriber]
      send(subscriber, :release)
      assert_receive {:released, ^subscriber}
      assert Transmitter.subscribers(client_id) == []
    end
  end

  describe "unsubscribe/1" do
    setup [:setup_transmitter]

    test "unsubscribe", context do
      client_id = context.client_id
      # first we create the subscription
      assert :ok = Transmitter.subscribe(client_id)
      context = run_setup(context, :setup_connection)
      assert_receive {Tortoise, {:transmitter, _socket}}
      # attempt to unsubscribe from the transmitter
      :ok = Transmitter.unsubscribe(client_id)
      assert Transmitter.subscribers(client_id) == []
      # Refresh the socket which should trigger broadcast of the
      # connection to the subscribers. We should no longer be
      # subscribed at this point, so we should not receive the
      # broadcast.
      _context = run_setup(context, :setup_connection)
      refute_receive {Tortoise, {:transmitter, _socket}}
    end
  end

  describe "publish/3" do
    setup [:setup_transmitter, :setup_connection]

    test "publishing on a pipe", context do
      client_id = context.client_id
      assert :ok = Transmitter.subscribe(client_id)
      assert_receive {Tortoise, {:transmitter, pipe}}
      publish = %Package.Publish{topic: "foo"}

      Transmitter.publish(pipe, publish)
      {:ok, package} = :gen_tcp.recv(context.server, 0)

      assert Package.decode(package) == publish
    end

    test "receiving a new pipe during a publish if the socket is closed", context do
      client_id = context.client_id
      parent = self()
      publish = %Package.Publish{topic: "foo"}

      subscriber =
        spawn_link(fn ->
          {:ok, pipe} = Transmitter.subscribe_await(client_id)
          send(parent, {:subscriber_pipe, pipe})
          {:ok, pipe} = Transmitter.publish(pipe, publish)
          # Now the parent will close the socket belonging to the pipe
          # and start a new one. The next publish will get the newly
          # created socket when it attempt to publish.
          receive do
            :retry_publish ->
              # this publish should receive the new pipe
              {:ok, pipe} = Transmitter.publish(pipe, publish)
              send(parent, {:subscriber_pipe, pipe})
          end
        end)

      assert_receive {:subscriber_pipe, %Pipe{socket: original_socket}}
      {:ok, package} = :gen_tcp.recv(context.server, 0)
      assert Package.decode(package) == publish
      :ok = :gen_tcp.close(context.client)

      send(subscriber, :retry_publish)
      context = run_setup(context, :setup_connection)

      {:ok, package} = :gen_tcp.recv(context.server, 0)
      assert Package.decode(package) == publish
      assert_receive {:subscriber_pipe, %Pipe{socket: new_socket}}
      # the new socket should be different than the original socket
      refute new_socket == original_socket
    end

    # test "pipe", context do
    #   # is this actually smart? or am i abusing "into" here?
    #   [
    #     %Package.Publish{topic: "hello", payload: "foo"},
    #     %Package.Publish{topic: "hello2", payload: "bar"},
    #     %Package.Publish{topic: "hello3", payload: "baz"}
    #   ]
    #   |> Enum.into(%Pipe{client_id: context.client_id, socket: context.client})
    # end
  end
end
