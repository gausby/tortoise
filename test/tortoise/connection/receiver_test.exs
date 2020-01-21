defmodule Tortoise.Connection.ReceiverTest do
  use ExUnit.Case

  doctest Tortoise.Connection.Receiver

  alias Tortoise.Package
  alias Tortoise.Connection.Receiver
  alias Tortoise.Integration.TestTCPTunnel

  setup context do
    {:ok, %{session_ref: context.test}}
  end

  def setup_receiver(context) do
    {:ok, ref, transport} = TestTCPTunnel.new(Tortoise.Transport.Tcp)

    opts = [
      session_ref: context.session_ref,
      transport: transport,
      parent: self()
    ]

    {:ok, receiver_pid} = Receiver.start_link(opts)
    {:ok, %{connection_ref: ref, transport: transport, receiver_pid: receiver_pid}}
  end

  def setup_connection(%{connection_ref: ref} = context) when is_reference(ref) do
    {:ok, _connection} = Receiver.connect(context.receiver_pid)
    assert_receive {:server_socket, ^ref, server_socket}
    {:ok, Map.put(context, :server, server_socket)}
  end

  def setup_connection(_) do
    raise "run `:setup_receiver/1` before `:setup_connection/1` in the test setup"
  end

  describe "receiving" do
    setup [:setup_receiver, :setup_connection]

    # when a message reached a certain size an issue where the message
    # got chunked on the connection lead to a crash in the
    # receiver. These two tests was set in place to help ironing out
    # this error, they should probably be refactored at some point,
    # probably as property based tests

    test "receive a message of 1460 bytes", context do
      payload = :crypto.strong_rand_bytes(1448)
      package = %Package.Publish{topic: "foo/bar", payload: payload}

      :ok = :gen_tcp.send(context.server, Package.encode(package))

      assert_receive {:incoming, data}
      assert ^package = Package.decode(data)
    end

    test "receive a larger message of about 5000 bytes", context do
      # payload = :crypto.strong_rand_bytes(268_435_146)
      payload = :crypto.strong_rand_bytes(5000)
      package = %Package.Publish{topic: "foo/bar", payload: payload}

      :ok = :gen_tcp.send(context.server, Package.encode(package))

      assert_receive {:incoming, data}, 10_000
      assert ^package = Package.decode(data)
    end

    test "very slow connection", context do
      Process.flag(:trap_exit, true)
      receiver_pid = context.receiver_pid
      # Send a byte, one at a time, into the receiver. This has been
      # observed in the wild and it caused a faulty pattern match to
      # report it as an invalid_header_length protocol violation
      :ok = :gen_tcp.send(context.server, <<0b11010000>>)
      refute_receive {:EXIT, ^receiver_pid, {:protocol_violation, :invalid_header_length}}, 400
      :ok = :gen_tcp.send(context.server, <<0>>)
      assert_receive {:incoming, data}, 10000
      assert %Package.Pingresp{} = Package.decode(data)
    end
  end

  describe "invalid packages" do
    setup [:setup_receiver, :setup_connection]

    test "invalid header length", %{receiver_pid: receiver_pid} = context do
      Process.flag(:trap_exit, true)
      # send too many bytes into the receiver, the header parser
      # should throw a protocol violation on this
      :ok = :gen_tcp.send(context.server, <<1, 255, 255, 255, 255, 0>>)
      assert_receive {:EXIT, ^receiver_pid, {:protocol_violation, :invalid_header_length}}, 5000
    end
  end
end
