defmodule Tortoise.Connection.ReceiverTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Connection.Controller

  alias Tortoise.Package
  alias Tortoise.Connection.{Receiver, Transmitter, Controller}

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_receiver(context) do
    opts = [client_id: context.client_id]
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    {:ok, _pid} = Receiver.start_link(opts)
    {:ok, _pid} = Transmitter.start_link(opts)
    :ok = Receiver.handle_socket(context.client_id, {Tortoise.Transport.Tcp, client_socket})
    {:ok, %{client: client_socket, server: server_socket}}
  end

  def setup_controller(context) do
    Registry.register(Registry.Tortoise, {Controller, context.client_id}, self())
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
  end
end
