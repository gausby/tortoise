defmodule Tortoise.Connection.ReceiverTest do
  use ExUnit.Case
  # use EQC.ExUnit
  doctest Tortoise.Connection.Controller

  # alias Tortoise.Package
  alias Tortoise.Connection.Receiver

  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_receiver(context) do
    opts = [client_id: context.client_id]
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    {:ok, _} = Receiver.start_link(opts)

    Transmitter.handle_socket(context.test, client_socket)

    {:ok, %{client: client_socket, server: server_socket}}
  end

  test "receive messages" do
  end
end
