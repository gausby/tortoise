defmodule Tortoise.Connection.ReceiverTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Connection.Controller

  alias Tortoise.Package
  alias Tortoise.Connection.{Receiver, Controller}

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_receiver(context) do
    opts = [client_id: context.client_id]
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    {:ok, receiver_pid} = Receiver.start_link(opts)
    :ok = Receiver.handle_socket(context.client_id, {Tortoise.Transport.Tcp, client_socket})
    {:ok, %{receiver_pid: receiver_pid, client: client_socket, server: server_socket}}
  end

  def setup_controller(context) do
    Registry.register(Tortoise.Registry, {Controller, context.client_id}, self())
    :ok
  end

  describe "receiving" do
    setup [:setup_receiver, :setup_controller]

    # when a message reached a certain size an issue where the message
    # got chunked on the connection lead to a crash in the
    # receiver. These two tests was set in place to help ironing out
    # this error, they should probably be refactored at some point,
    # probably as property based tests

    test "receive a message of 1460 bytes", context do
      payload = :crypto.strong_rand_bytes(1448)
      package = %Package.Publish{topic: "foo/bar", payload: payload}

      :ok = :gen_tcp.send(context.server, Package.encode(package))

      assert_receive {:"$gen_cast", {:incoming, data}}
      assert ^package = Package.decode(data)
    end

    test "receive a larger message of about 5000 bytes", context do
      # payload = :crypto.strong_rand_bytes(268_435_446)
      payload = :crypto.strong_rand_bytes(5000)
      package = %Package.Publish{topic: "foo/bar", payload: payload}

      :ok = :gen_tcp.send(context.server, Package.encode(package))

      assert_receive {:"$gen_cast", {:incoming, data}}, 10000
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
      assert_receive {:"$gen_cast", {:incoming, data}}, 10000
      assert %Package.Pingresp{} = Package.decode(data)
    end
  end

  describe "invalid packages" do
    setup [:setup_receiver]

    test "invalid header length", context do
      Process.flag(:trap_exit, true)
      receiver_pid = context.receiver_pid
      # send too many bytes into the receiver, the header parser
      # should throw a protocol violation on this
      :ok = :gen_tcp.send(context.server, <<1, 255, 255, 255, 255, 0>>)
      assert_receive {:EXIT, ^receiver_pid, {:protocol_violation, :invalid_header_length}}
    end
  end
end
