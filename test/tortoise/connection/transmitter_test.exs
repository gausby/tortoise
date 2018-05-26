defmodule Tortoise.Connection.TransmitterTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Transmitter

  alias Tortoise.Connection.Transmitter

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_transmitter(context) do
    opts = [client_id: context.client_id]
    {:ok, pid} = Transmitter.start_link(opts)
    {:ok, %{transmitter_pid: pid}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    :ok = Transmitter.handle_socket(context.test, {Tortoise.Transport.Tcp, client_socket})
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

  describe "get_socket/2" do
    setup [:setup_transmitter]

    test "get socket while offline (passive)", context do
      client_id = context.client_id
      parent = self()

      spawn_link(fn ->
        {:ok, socket} = Transmitter.get_socket(client_id, timeout: 5000, active: false)
        send(parent, {:got_socket, socket})
      end)

      refute_receive {:got_socket, {_transport, _socket}}
      _context = run_setup(context, :setup_connection)
      assert_receive {:got_socket, {_transport, socket}}
      assert is_port(socket)
      assert Transmitter.subscribers(client_id) == []
    end

    test "get socket while offline (active)", context do
      client_id = context.client_id
      parent = self()

      subscriber =
        spawn_link(fn ->
          {:ok, socket} = Transmitter.get_socket(client_id, timeout: 5000, active: true)
          send(parent, {:got_socket, socket})
          :timer.sleep(:infinity)
        end)

      refute_receive {:got_socket, {_transport, _socket}}
      _context = run_setup(context, :setup_connection)
      assert_receive {:got_socket, {_transport, socket}}
      assert is_port(socket)
      assert Transmitter.subscribers(client_id) == [subscriber]
    end

    test "remove active subscription when owner process terminates", context do
      context = run_setup(context, :setup_connection)
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
          {:ok, _socket} = Transmitter.get_socket(client_id, timeout: 5000, active: true)
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
      {:error, :timeout} = Transmitter.get_socket(client_id, active: true, timeout: 0)
      assert Transmitter.subscribers(client_id) == [self()]
      context = run_setup(context, :setup_connection)
      assert_receive {{Tortoise, ^client_id}, :socket, _socket}
      # attempt to unsubscribe from the transmitter
      :ok = Transmitter.unsubscribe(client_id)
      assert Transmitter.subscribers(client_id) == []
      # Refresh the socket which should trigger broadcast of the
      # connection to the subscribers. We should no longer be
      # subscribed at this point, so we should not receive the
      # broadcast.
      _context = run_setup(context, :setup_connection)
      refute_receive {{Tortoise, ^client_id}, :transmitter, _socket}
    end
  end
end
